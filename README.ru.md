# RZA

[English version](README.md)

RZA — низкоуровневый язык и промежуточное представление с явным временем жизни
памяти, проверяемыми обращениями к ней и управлением потока выполнения на уровне
ассемблера. Исходники имеют расширение `.rza`. Компилятор `rez3asm` проверяет их
и генерирует C23, а нативную оптимизацию и выбор инструкций выполняет C toolchain.

RZA предназначен для небольших вычислительных ядер, которым нужны фиксированные
бюджеты памяти и определённое поведение при ошибках, а не для скрытия
низкоуровневого программирования за высокоуровневым синтаксисом. Версия
[0.2.0](https://github.com/wtorso/rza/releases/tag/v0.2.0) — prerelease; язык и
host-интерфейсы могут меняться.

## Требования

Для сборки из исходников нужны [C3
0.8.5_1](https://github.com/c3lang/c3c/releases/tag/v0.8.5_1) с `c3c` в `PATH`,
компилятор C23 (GCC, Clang или Zig), Bash и стандартные командные утилиты. Для
запуска готового компилятора C3 не нужен, но для компиляции его C23-вывода всё ещё
нужен C compiler. Rust необязателен и используется только для сравнительных
программ и benchmark-проверок.

Команды ниже используют POSIX-совместимый shell. CI также собирает и тестирует
проект на Windows с Bash и Zig. Release-пакеты пока доступны только для Linux
x86_64 и Windows x86_64. Windows-бинарь использует динамический Microsoft C
runtime (`VCRUNTIME140.dll`) и `dbghelp.dll`; static CRT не входит в пакет.

## Сборка и запуск

Склонируйте репозиторий и соберите компилятор:

```sh
git clone https://github.com/wtorso/rza.git
cd rza
bash build_compiler.sh
```

Скрипт записывает компилятор в `./build/bin/rez3asm` на POSIX и
`./build/bin/rez3asm.exe` на Windows.
Соберите и запустите готовый standalone-пример:

```sh
mkdir -p build
./build/bin/rez3asm examples/hello.rza --emit-c -o build/hello.c
${CC:-cc} -std=c23 -O2 -pedantic -Wall -Wextra -Werror -I include/rza -I . \
  build/hello.c -o build/hello
./build/hello
```

Ожидаемый вывод:

```text
41
```

### Проверка без генерации C

```sh
./build/bin/rez3asm examples/hello.rza
```

Для корректной программы компилятор ничего не выводит и завершается со статусом 0.
При ошибках в исходнике он выводит диагностику `VIOLATION` и возвращает 1. Ошибки
командной строки и файлового ввода-вывода возвращают 2.

## Интерфейс командной строки

```text
rez3asm file.rza [--emit-c | --emit-lib] [-o file.c]
rez3asm --lsp
rez3asm --help
rez3asm --version
```

- Без output-флага компилятор выполняет только проверку.
- `--emit-c` генерирует standalone C-программу с `main`.
- `--emit-lib` генерирует C-библиотеку без `main` для встраивания в C host.
- `-o` записывает C в файл и включает генерацию даже без emit-флага. Без `-o`
  сгенерированный C выводится в standard output.
- `--lsp` запускает языковой сервер через standard input и output.
- Отдельный `--help` выводит справку и возвращает 0; без аргументов справка
  выводится в stderr со статусом 2. Отдельный `--version` выводит
  `rez3asm 0.2.0` и возвращает 0.

`build_compiler.sh` создаёт компилятор, но не устанавливает его в `PATH`;
вызывайте его по пути или используйте установщик ниже.

## Установка и release-пакеты

### Установка для текущего пользователя

Из каталога исходников:

```sh
PREFIX="$HOME/.local" bash install.sh
export PATH="$HOME/.local/bin:$PATH"
```

По умолчанию `PREFIX` равен `/usr/local`; `DESTDIR` поддерживается для staged
установок. Установщик не вызывает sudo. Он копирует native compiler, оба runtime
headers и лицензию. При компиляции сгенерированного C после установки добавьте
`-I "$HOME/.local/include/rza"` к флагам C compiler.

Из распакованного binary-пакета можно установить готовый компилятор без C3:

```sh
RZA_COMPILER=./rez3asm PREFIX="$HOME/.local" bash install.sh
```

### Binary-архивы

Скачайте нужный архив и `SHA256SUMS` со страницы
[релиза 0.2.0](https://github.com/wtorso/rza/releases/tag/v0.2.0), затем
проверьте и распакуйте его. `--ignore-missing` позволяет скачать архив только
одной платформы:

```sh
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf rza-0.2.0-linux-x86_64.tar.gz
cd rza-0.2.0-linux-x86_64
./rez3asm --version
```

Архив содержит native compiler, runtime headers, исходники, тесты, benchmarks и
примеры. Quickstart выше также работает из этого каталога. Файл `RELEASE.txt`
записывает версию, полный source commit, target, версию C3 и `RZA_DIRTY=0`.
Перед публикацией архивы собираются в двух чистых checkout и должны совпадать
байтами. Checksums
проверяют целостность, но не являются цифровой подписью.

## Память и выполнение

Программа использует шестнадцать знаковых 64-битных регистров от `%r0` до `%r15`.
Память организована в ячейки; RZA-код не адресует её через сырые указатели.

- `field` — корневая рамка, существующая всю программу.
- `cav name, parent` создаёт рамку, владеющую ареной памяти фиксированного размера.
- `res cell, frame, size` резервирует нуле-инициализированную ячейку в живой рамке.
- `med ref, cell, frame` создаёт проверяемую ссылку — медиатор. Проверки поколений
  не позволяют старому медиатору обратиться к повторно использованной памяти.
- `decay frame` инвалидирует рамку и всё её поддерево. Последующий доступ через
  затронутый медиатор вызывает runtime `FAULT`.
- `raise cell, ancestor` меняет владельца только для статической проверки. Память
  не перемещается, а время жизни исходной рамки не продлевается. Домашняя рамка
  обязана оставаться живой при любом доступе.
- `casc ... endc` проверяет все входные медиаторы перед выполнением блока. Мёртвый
  вход во время выполнения пропускает весь блок с `ABORT`; выход — ячейка 8 байт.
- `acasc ... endc` ставит работу в ограниченную cooperative FIFO. `await` выполняет
  очередь и возвращает число успешных задач. Это не параллелизм на OS threads и не
  сетевой asynchronous I/O.

RZA сочетает статическую проверку с определёнными исходами во время выполнения.
Статически обнаруживаемые ошибки владения и постоянный выход за границы вызывают
`VIOLATION`. Мёртвые медиаторы, динамический выход за границы, недопустимая
арифметика и исчерпание runtime-ресурсов вызывают `FAULT`. Каскад с мёртвым входом
пропускает тело с `ABORT`. Эти проверки не доказывают прикладную логику и не
покрывают сырые указатели, offsets и lifetimes, которыми управляет C host.

Процедуры начинают работу с чистыми регистрами. Значения передаются через ячейки,
а не регистры параметров или возвращаемого значения. Рекурсия запрещена.

`add`, `sub`, `mul`, `inc` и `dec` выполняют wrapping modulo 2^64. Checked-варианты
`cadd`, `csub`, `cmul`, `cinc` и `cdec` вместо этого вызывают `FAULT` при signed
overflow. Checked arithmetic не доказывает прикладные инварианты вроде
неотрицательной quota: их нужно проверять отдельно. `shr` — арифметический сдвиг
вправо, `ushr` — логический. Деление на ноль, переполняющие signed
division/remainder и недопустимый сдвиг вызывают `FAULT`.
Постоянный выход за границы отклоняется при проверке; зависящий от регистра —
во время выполнения.

`crc32c DST, STATE, WORD` обновляет CRC32C над 8 байтами `WORD` в little-endian.
Initial/final XOR остаются явными. Runtime использует SSE4.2 при поддержке CPU,
иначе bitwise fallback даёт тот же результат.

Runtime использует фиксированное хранилище. После инициализации он не вызывает
`malloc`, `realloc` или `free`.

## Ограниченные views

`view DST, SOURCE, OFFSET, LENGTH` создаёт медиатор для поддиапазона существующего
медиатора без выделения памяти и копирования данных:

```asm
view payload_m, input_m, %r2, %r3
loadb %r0, [payload_m + %r1]
```

Для raw-ячеек смещение и длина задаются в байтах, для typed — в элементах. Оба
операнда могут быть `i64`-константой или регистром. Отрицательные или заведомо
невозможные постоянные диапазоны дают `VIOLATION`; динамические ошибки и мёртвый
источник — `FAULT`. Immediate-длина фиксирует границу destination для статических
проверок даже при динамическом смещении или родительском диапазоне. Динамическая
длина сохраняет runtime bounds checks. Пустые views допустимы, в том числе на
конце ячейки; вложенные views не могут расширить родителя.

Views наследуют owner, home, lifetime и generation-проверки источника. Async OUT
переиспользует свои фиксированные 8 байт при каждом enqueue и увеличивает
per-allocation generation, поэтому старые медиаторы и views не видят новую
публикацию как прежнюю. Views создаются на верхнем уровне, в процедурах и внутри
синхронных каскадов. Block-local view виден только в своём каскаде. Тела async-каскадов views не
создают; обе формы принимают заранее созданные views как входы.

## Именованные записи (typed layouts)

Плоские записи описывают размеры и выравнивание полей, а также число элементов:

```asm
layout Entry: key:i64, value:i64
res entries, field, Entry[2]
med entries_m, entries, field

mov %r0, 0
mov %r1, 42
store [entries_m + %r0].key, %r1
store [entries_m + %r0].value, %r1
load %r2, [entries_m + 0].value
print %r2
ret
```

Для typed-ячейки значение после `+` — номер элемента, а не смещение в байтах.
Компилятор вычисляет stride записи и смещения полей. Для полей `i64` используются
`load`/`store`, для `u8` — `loadb`/`storeb`. Raw-ячейки используют byte offsets и
не имеют селектора поля.

[Пример ring buffer](examples/ring_buffer.rza) показывает typed-состояние,
массив записей и арифметику индексов с фиксированной ёмкостью.

## Встраивание в C

Сгенерируйте библиотеку и скомпонуйте её с готовым host:

```sh
./build/bin/rez3asm examples/shop.rza --emit-lib -o build/shop.c
${CC:-cc} -std=c23 -O2 -pedantic -Wall -Wextra -Werror -I include/rza -I . \
  build/shop.c examples/shop_host.c -o build/shop_host
./build/shop_host
```

Host завершается со статусом 0 после того, как `rza_boot` выполняет программу
shop. Его вывод совпадает с `examples/shop.expected` и заканчивается `DEAD`:
последний `probe` видит уничтоженную рамку корзины. Библиотека экспортирует
`rza_boot`, точки входа процедур, функции доступа к рамкам и медиаторам,
`rza_deref_cell`, `rza_arena_alloc` и `rza_await`.

Версия host ABI — 5. Пересобирайте все C translation units с одинаковыми headers
и generated code. Проверки RZA не делают произвольный host C безопасным: host
остаётся ответственным за собственные указатели, смещения и времена жизни объектов.

`rza_boot` выполняется один раз и возвращает `RzaResult`. Повторный boot и reentry
из diagnostic callback возвращают `RZA_FAULT_ENTRY_STATE`. Процедуры также
возвращают `RzaResult`; их неявные рамки закрываются и при успехе, и при ошибке,
поэтому вызовы можно повторять. `rza_await` возвращает `RzaAwaitResult` с числом
завершённых задач и результатом. Любой `FAULT` отменяет очередь и сбрасывает
pending-флаги; выполненные записи сохраняются, а отменённые OUT не публикуются.

Standalone-программа печатает диагностику и завершается со статусом 1 при `FAULT`.
Библиотека возвращает первый код ошибки и строку без завершения процесса и вывода
по умолчанию. Для диагностики установите `rza_set_diagnostic_handler`.
Transactional rollback отсутствует: записи до ошибки остаются видимыми, а host
обязан восстановить или отбросить прикладное состояние по своим правилам.

## Примеры и редакторы

- [hello](examples/hello.rza): минимальная запускаемая программа.
- [ring_buffer](examples/ring_buffer.rza): ограниченный FIFO с typed-состоянием,
  отклонением операций при empty/full и wraparound.
- [shop](examples/shop.rza): переходы состояний и встраивание в C host.

Там, где применимо, рядом с примером находится `.expected` с ожидаемым выводом.
[Расширение VS Code](https://github.com/wtorso/rza-vscode) подсвечивает синтаксис,
показывает диагностику, hover, определения, references и контекстный completion
через настоящий языковой сервер. Rename поддерживает layouts, поля, рамки, ячейки,
медиаторы и процедуры, использует edits с версией документа и возвращается только
если новая программа проходит checker. Поскольку каждый `.rza` — самостоятельная
программа, навигация и rename работают внутри текущего документа; labels не
поддерживаются. Лёгкие режимы для
[Emacs и Neovim](https://github.com/wtorso/rza-editors) подсвечивают синтаксис без
компилятора.

## Измерения

На Linux с установленными `rustc` и `objdump` выполните:

```sh
bash bench/run.sh
```

Benchmarks сравнивают CRC32C, hash-table, ring-buffer, parser и protocol workloads
на RZA, C и Rust; отдельно измеряются RZA-only call и async dispatch. Compile/runtime
costs записываются раздельно, disassembly сохраняется.
[Руководство benchmark](bench/README.md) описывает выбор toolchain, выходные файлы
и границы измерений. Результаты относятся только к записанным машине, toolchain и
workload; они не доказывают универсальное преимущество над C или Rust.

## Текущие ограничения

- Поддерживаются только плоские записи `u8`/`i64` и fixed-size arrays. Nested и
  packed layouts, unions, bitfields и portable wire ABI не реализованы.
- Нет OS threads, garbage collection, рекурсии, физического перемещения памяти,
  transactional rollback или сетевых примитивов общего назначения.
- Нет общего SIMD/intrinsic интерфейса и собственного native optimizing backend.
  Фиксированный opcode `crc32c` использует runtime feature detection и portable
  fallback. Остальную target-specific генерацию выполняет выбранный C23 compiler.
- Фиксированные бюджеты задают явные пределы ресурсов и не растут автоматически.
- Checker не доказывает корректность прикладной логики и не санитизирует host C.

## Проверка

Соберите компилятор и выполните полный suite:

```sh
bash build_compiler.sh
bash run_tests.sh
```

Ожидаемый результат: `PASS=201 FAIL=0` на POSIX и `PASS=200 FAIL=0` на Windows.
На Windows не запускаются только специфичные для Linux проверки исходников
benchmark; на Linux для них также нужен `rustc`.

Другие поддерживаемые варианты C toolchain:

```sh
CC=clang bash run_tests.sh
CC="zig cc" RUST_CC=clang bash run_tests.sh
```

`RUST_CC` выбирает linker для Rust static libraries, но не заменяет C compiler для
сгенерированного RZA-кода. CI запускает Linux GCC/Clang/Zig, Windows Zig, а также
unit, packaging, Extension Host и production-dependency проверки VS Code. Linux Clang
дополнительно запускает полный suite с ASan и UBSan. Linux
GCC и Windows дополнительно проверяют воспроизводимые пакеты и staged install.
Release workflow поддерживает ручной dry run и публикацию из version tags.

## Структура репозитория

- `src/`: CLI, языковой сервер, модель языка, layouts, checker, C23 emitter и
  memory helpers компилятора.
- `include/rza/`: публичные headers fixed-storage C23 runtime.
- `build/bin/`: игнорируемый результат сборки native compiler.
- `install.sh`: установка native compiler и headers через `PREFIX` и `DESTDIR`.
- `release/`: воспроизводимая упаковка, smoke-проверки и release notes.
- `examples/`: небольшой набор практических примеров и ожидаемый вывод.
- `tests/`: positive, negative, runtime, ABI, LSP, fuzz и style проверки.
- `tests/reference/`: эталонный C23 checker и статическая reference-программа.
- `bench/`: сравниваемые workloads, timing и disassembly checks.
- `editors/vscode`: расширение VS Code как отдельный submodule.

## Лицензия

RZA распространяется по [лицензии MIT](LICENSE).
