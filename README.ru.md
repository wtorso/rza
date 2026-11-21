# RZA

[English version](README.md)

RZA — низкоуровневый язык и промежуточное представление с явным временем жизни
памяти, проверяемыми обращениями к ней и управлением потока выполнения на уровне
ассемблера. Исходники имеют расширение `.rza`. Компилятор `rez3asm` проверяет их
и генерирует C23, а нативную оптимизацию и выбор инструкций выполняет C toolchain.

RZA предназначен для небольших вычислительных ядер, которым нужны фиксированные
бюджеты памяти и определённое поведение при ошибках, а не для скрытия
низкоуровневого программирования за высокоуровневым синтаксисом. Версия
[0.3.0](https://github.com/wtorso/rza/releases/tag/v0.3.0) — prerelease; язык и
host-интерфейсы могут меняться.

## Требования

Для сборки из исходников нужны [C3
0.8.5_1](https://github.com/c3lang/c3c/releases/tag/v0.8.5_1) с `c3c` в `PATH`,
компилятор C23 (GCC, Clang, Zig или MSVC на Windows), Bash и стандартные командные
утилиты. Для запуска готового компилятора C3 не нужен, но для компиляции его
C23-вывода всё ещё нужен C compiler. Rust необязателен для сборки и использования
компилятора, но полный suite требует `rustc` для сравнительных программ и
benchmark-проверок.

Команды ниже используют POSIX-совместимый shell. CI также собирает и тестирует
проект на Windows с Bash, Zig и MSVC. Release-пакеты пока доступны только для Linux
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

### Сгенерированные программы на Linux ARM64 и RV64

`rez3asm` остаётся x86_64 host-компилятором. Его C23-вывод можно кросс-компилировать
для little-endian Linux AArch64 и RV64; сам C3 compiler на эти архитектуры не
переносится. Публичная опция выбора target в RZA CLI не добавляется.

Проверенная конфигурация:

- Zig 0.17.1 с Clang 22.1.8 в роли cross-compiler.
- `aarch64-linux-musl`: little-endian LP64, static musl, внешний sysroot не нужен,
  launcher `/usr/bin/qemu-aarch64-static` без префикса `-L`.
- `riscv64-linux-musl`: little-endian LP64D, static musl, внешний sysroot не нужен,
  launcher `/usr/bin/qemu-riscv64-static` без префикса `-L`.
- QEMU 11.1.3 и `readelf` для запуска и проверки архитектуры.

Начиная с того же `build/hello.c`:

```sh
zig cc -target aarch64-linux-musl -std=c23 -O2 -static \
  -pedantic -Wall -Wextra -Werror -I include/rza -I . \
  build/hello.c -o build/hello-arm64
qemu-aarch64-static build/hello-arm64

zig cc -target riscv64-linux-musl -std=c23 -O2 -static \
  -pedantic -Wall -Wextra -Werror -I include/rza -I . \
  build/hello.c -o build/hello-rv64
qemu-riscv64-static build/hello-rv64
```

Обе программы печатают `41`. На non-x86 пути SSE4.2 и другой x86-specific код
исключаются при компиляции; CRC32C использует portable fallback с независимыми
известными векторами. ARM CRC acceleration не заявляется.

Внутренний test runner принимает связанные настройки архитектуры и launcher:

```sh
CC="zig cc -target aarch64-linux-musl -static" \
RZA_TARGET_ARCH=aarch64 \
RZA_TARGET_LAUNCHER=qemu-aarch64-static \
RZA_TARGET_LOG="$PWD/build/target-aarch64.exec.log" \
RZA_TARGET_EXPECTED_PASS=172 \
bash run_tests.sh
```

Для RV64 укажите `riscv64`, `riscv64-linux-musl`, `qemu-riscv64-static` и отдельный
log path. Каждый target executable централизованно проверяется на ELF64,
little-endian и требуемый machine ID до запуска QEMU. Отсутствие настроек или
инструментов — infrastructure failure, а не fallback на host execution.

Проверенный target run имеет `PASS=172` и 1037 logged executions на каждую
архитектуру. Log включает mutation/shrink попытки, поэтому 1037 не является числом
семантических тестов. Он включает numeric8, numeric16 и numeric32 oracles, каждый
с 64 valid + 64 fault программами, и 56 непосредственные RZA workload-проверки.
Также в него входят девять numeric8 shrink-signature executions, добавленных после
исходного platform baseline. C3/compiler internals, LSP, статическая диагностика,
deterministic artifacts, release/package, native Rust comparisons и timing —
host-only или отдельные native gates, а не доказательство ARM/RV64 execution.

Результаты относятся только к cross-build и QEMU user-mode validation. Реальное
hardware, big-endian, другие libc/ABI, ARM32, RV32 и cross-target ASan/UBSan не
проверялись; выводов о performance нет. Release-архивы по-прежнему содержат только
x86_64 host compiler; ARM/RV64 compiler assets не создаются.

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
  `rez3asm 0.3.0` и возвращает 0.

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
[релиза 0.3.0](https://github.com/wtorso/rza/releases/tag/v0.3.0), затем
проверьте и распакуйте его. `--ignore-missing` позволяет скачать архив только
одной платформы:

```sh
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf rza-0.3.0-linux-x86_64.tar.gz
cd rza-0.3.0-linux-x86_64
./rez3asm --version
```

Архив содержит native compiler, runtime headers, исходники, тесты, benchmarks и
примеры. Quickstart выше также работает из этого каталога. Файл `RELEASE.txt`
записывает версию, полный source commit, target, версию C3 и `RZA_DIRTY=0`.
Перед публикацией архивы собираются в двух чистых checkout и должны совпадать
байтами. Checksums
проверяют целостность, но не являются цифровой подписью.

## Память и выполнение

Программа использует шестнадцать 64-битных регистров от `%r0` до `%r15` как
битовые контейнеры. Инструкция определяет интерпретацию этих битов. Память
организована в ячейки; RZA-код не адресует её через сырые указатели.

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

Дополнительный заголовок со скобками объявляет возможности медиаторов процедуры:

```asm
proc convert(input_m: ro, result_m: rw):
```

Имена ссылаются на существующие глобальные медиаторы и layouts их ячеек. `ro`
разрешает чтение, probe, views и использование входом каскада; `rw` также разрешает
запись. Доступ через неперечисленный медиатор и объявление нового медиатора внутри
такой процедуры — статические violations. Локальный view наследует возможность
источника. Глобальный view — отдельный медиатор: перечисление источника не
перечисляет view. Caller с contract обязан предоставить все возможности callee и
не может повысить `ro` до `rw`, в том числе через цепочку вызовов. Пустой
`proc pure():` запрещает доступ к медиаторам. Прежний `proc name:` не меняется.
Contract содержит не более 64 медиаторов и полностью стирается до генерации C.
Диагностика доступа называет процедуру; ошибка вызова также называет прямой callee.

`add`, `sub`, `mul`, `inc` и `dec` выполняют wrapping modulo 2^64. Checked-варианты
`cadd`, `csub`, `cmul`, `cinc` и `cdec` вместо этого вызывают `FAULT` при signed
overflow. Checked arithmetic не доказывает прикладные инварианты вроде
неотрицательной quota: их нужно проверять отдельно. `shr` — арифметический сдвиг
вправо, `ushr` — логический. Деление на ноль, переполняющие signed
division/remainder и недопустимый сдвиг вызывают `FAULT`.
Постоянный выход за границы отклоняется при проверке; зависящий от регистра —
во время выполнения.

### 8-, 16- и 32-битные типизированные операции

Суффиксы `.i8`, `.u8`, `.i16`, `.u16`, `.i32` и `.u32` выбирают знаковую или
беззнаковую семантику для `mov`, `load`, `store`, `add`, `sub`, `mul`, `inc`,
`dec`, `cadd`, `csub`, `cmul`, `cinc`, `cdec`, `and`, `or`, `xor`, `div`, `mod`,
`shl` и `ushr`. Знаковые типы также поддерживают `shr` и `slt`, беззнаковые — `ult`.
Каждая ширина имеет 43 сочетания операции и типа, всего 129. Typed `.i64`, `u64`,
floating point и недопустимые пары по-прежнему отклоняются. `loadb`/`storeb`
остаются алиасами только `load.u8`/`store.u8`.

Typed-операции читают только младшие 8, 16 или 32 бита регистровых операндов.
Знаковый результат знаково расширяется в 64-битный регистр, беззнаковый — нулевым
расширением. Typed-store записывает ровно этот младший bit pattern. Тип load/store
обязан точно совпадать с типом поля layout. Raw-ячейки используют byte offsets,
typed-ячейки — element indices. Alignment равен 2 для 16-битных и 4 для 32-битных
типов. Raw multi-byte доступ может быть unaligned и использует определённое
копирование байтов (`memcpy` в C23), а не narrow pointer casts. Доступ к отдельным
байтам использует определённые unsigned-char loads/stores. Представление памяти
следует target byte order и не является portable wire format.

Тесты размещают независимые canaries вокруг raw stores и рядом с 32-битным полем
layout; generated C обязан копировать ровно два или четыре байта соответственно.
Async-тест печатает checked 32-битный результат непосредственно в callback и после
result-load, поэтому неканонические старшие биты не могут просочиться в наблюдение.

Wrapping-арифметика выполняется modulo 256, 65536 или 4294967296. Checked-арифметика
вызывает `FAULT` вне -128..127, -32768..32767 или -2147483648..2147483647 для signed
и 0..255, 0..65535 или 0..4294967295 для unsigned. Знаковое деление округляется к
нулю; нулевой делитель и signed minimum / -1 вызывают `FAULT` для div и mod.
Беззнаковые div/mod вызывают `FAULT` только на нулевом делителе. Счётчики сдвига —
0..7, 0..15 или 0..31: `shl` отбрасывает старшие биты, знаковый `shr` заполняет
знаковый бит, `ushr` — нули.

Decimal-литералы используют те же signed/unsigned диапазоны. Любой leading minus
для unsigned, включая `-0`, отклоняется. Typed hex — `0x0`..`0xff`, `0x0`..`0xffff`
и `0x0`..`0xffffffff`; ведущие нули разрешены, отрицательный hex запрещён. Signed
hex с установленным старшим битом обозначает отрицательное значение после
знакового расширения. `print` по-прежнему печатает signed i64.

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

Views наследуют owner, home, lifetime и generation-проверки источника. Медиаторы,
созданные host, должны содержать корректно выровненные metadata и описывать
фактический размер объекта. Runtime проверяет арифметику и согласованность
metadata, но не может валидировать произвольные non-null C-адреса. Async OUT
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
Компилятор вычисляет stride записи и смещения полей по ширине и alignment каждого
типа. Для `i64` используются прежние `load`/`store`; для `u8`, `i8`, `u16`, `i16`,
`u32` и `i32` — `load`/`store` с суффиксом, точно совпадающим с типом поля. Алиасы
`loadb`/`storeb` доступны только для `u8`. Raw-ячейки используют byte offsets и не
имеют селектора поля.

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

- Поддерживаются только плоские записи `u8`/`i8`/`u16`/`i16`/`u32`/`i32`/`i64` и
  fixed-size arrays. Nested и packed layouts, unions, bitfields и portable wire ABI
  не реализованы.
- Fixed-width integer работа не завершена: `u64` и typed `.i64` не активны, поэтому
  финальная 64-битная группа ещё впереди. Floating point и Stage 3 не начинались.
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

Ожидаемый результат: `PASS=278 FAIL=0` на POSIX и Windows MSVC, `PASS=277 FAIL=0`
на Windows Zig. Benchmark correctness требует `rustc` и запускается на POSIX и
Windows MSVC. Windows Zig сохраняет прежний объём из-за конфликта weak symbols
Rust compiler-builtins и Zig compiler-rt при связывании static library; не маскируйте его
через `FORCE:MULTIPLE`. Полный timing-скрипт `bench/run.sh` остаётся Linux-only;
MSVC запускает correctness и timer.

Другие поддерживаемые варианты C toolchain:

```sh
CC=clang bash run_tests.sh
CC="zig cc" RUST_CC=clang bash run_tests.sh
CC=cl bash run_tests.sh
```

`CC=cl` выбирает Microsoft `cl.exe` и требует Git Bash внутри x64 Native Tools
environment для Visual Studio 2022 с Windows SDK. `cc.sh` передаёт `/std:clatest`,
`/W4`, `/WX` и `/TC`; `clang-cl` — другой frontend и не заменяет эту проверку.
MSVC не предоставляет GCC-compatible UBSan, поэтому sanitizer-проверки остаются
на GCC, Clang и Zig. Windows Zig остаётся поддерживаемым с прежними UBSan и
packaging-проверками.

`RUST_CC` выбирает linker для Rust static libraries, но не заменяет C compiler для
сгенерированного RZA-кода. CI запускает Linux GCC/Clang/Zig, Windows Zig, Windows
MSVC `cl.exe`, Linux AArch64/RV64 QEMU target jobs, а также unit, packaging,
Extension Host и production-dependency проверки VS Code. Linux Clang дополнительно
запускает полный suite с ASan и UBSan. Linux GCC и оба Windows-компилятора
дополнительно проверяют воспроизводимые пакеты и staged install. Release workflow
поддерживает ручной dry run и публикацию из version tags.

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
