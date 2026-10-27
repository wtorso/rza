---
name: rez3-asm
description: Писать и проверять код на REZ3-ASM (.rza) — типизированный ассемблер владения RESONANCE-3 (рамки, ячейки, медиаторы, каскады, I1–I4)
whenToUse: Когда пишу или правлю файлы .rza, добавляю инструкции в транспайлер, отлаживаю VIOLATION-диагностику
---

# REZ3-ASM — как писать

Модель: 4 кирпича (Field/Cavity/Resonator/Mediator), 8 операций, 4 инварианта.
Полная нормативная спецификация: `SPEC.md` (EBNF, семантика, стирание).
Примеры-эталоны: `tests/*.rza` (fib, counter, back_button, cascade).

## Шпаргалка по языку

`;` — комментарий. `field` — неявная бессмертная корневая рамка (не объявляется,
не умирает). Имена — нижний регистр, медиаторы с суффиксом `_m`.

```
cav   NAME, PARENT            ; рамка; PARENT = field | живая рамка
res   NAME, CAV, SIZE         ; ячейка SIZE байт в ЖИВОЙ рамке         [I1]
med   NAME, RES, ISSUER       ; проход; ISSUER = владелец | предок     [I2]
casc  NAME: M1,M2 -> OUT[CAV] ; sync-каскад до endc; OUT — новая ячейка [I3]
acasc NAME: M1 -> OUT         ; async: связи и OUT только в field      [I3]
endc / raise RES, CAV [I4] / decay CAV / probe MED / load %rN, [MED+off]
loadb %rN, [MED+off]       ; байт, zero-extend; off = imm | %rN
```

Данные: `mov`, `store [MED+off], %rN`, ALU трёхоперандные
(`add %rD, %rA, %rB`: sub mul div mod and or xor shl shr), `inc`/`dec`,
метки `name:`, `jmp`/`brz`/`brnz`, `proc NAME:` … `call`/`ret`, `print`.
Последний операнд ALU — регистр или i32-константа. Регистры i64 `%r0..%r15`.

## Правила, о которые чаще всего бьются

- **Порядок операндов sub/div/mod/shr: `op %rD, %rA, %rB` = D = A ∘ B.**
  `sub %r8, %rX, %r8` после `mov %r8, K` даёт %rX−K, а НЕ K−%rX: для
  сравнений вида `K - x > 0` пиши `sub %r8, %r8, %rX`. Для проверок
  равенства (brz/brnz без shr) порядок безразличен, для знака — нет.
- load/store ТОЛЬКО через медиатор, в т.ч. к своей ячейке. Сырого адреса нет.
- Переходы — только внутри текущего лексического блока (верхний уровень /
  proc / тело каскада). Из каскада наружу — только endc или abort.
- Внутри casc load/store — только по медиаторам из списка входа.
- proc видит свои локальные имена + медиаторы на ячейки `field` и
  глобальных рамок (SPEC §6); чужие proc-медиаторы — [SCOPE].
- Запрещённые имена — всегда, не только в lib-режиме (SPEC §9): proc ∉
  {boot, arena_alloc, deref_cell} и не с префиксов `frame_`/`med_` [STRUCT];
  рамка ≠ имя существующего proc [DUP]; имена медиаторов уникальны
  глобально [DUP].
- `ret` на верхнем уровне = конец программы, должен быть последним.
- decay field запрещён; двойной decay — ошибка; decay убивает поддерево
  и все медиаторы на него рекурсивно.
- Мёртвый медиатор: load/store = runtime FAULT (статически легально!),
  вход sync-каскада = статический [I3].

## Петля проверки (всегда прогонять)

```sh
cd rza
./rez3asm.exe path/to/file.rza            # только проверка
./rez3asm.exe path/to/file.rza --emit-c   # посмотреть C99
./rez3asm.exe path/to/file.rza --emit-lib # C99-библиотека без main: proc → rza_NAME, хост-API rza_frame_*/rza_med_* (SPEC §11)
./rez3asm.exe path/to/file.rza -o out.c   # -o без флагов тоже включает эмиссию C
./rez3asm.exe --lsp                       # LSP-сервер на stdio (SPEC §12) — так редактор получает диагностику
bash run_tests.sh                          # пересборка транспайлера + все тесты
```

Диагностика: `VIOLATION line N [RULE]: msg` в stderr; RULE ∈
I1, I2, I3, I4, DECAY, DUP, STRUCT, SCOPE. Читай правило, а не только строку.

## Рантайм и генерация

`refs/rez3.h` (не менять) + `refs/rez3ext.h`. RezCellMed хранит cell, текущего
и домашнего владельцев, поколения и size. Выход за ячейку и опасная арифметика —
FAULT; wrapping add/sub/mul определён. Арена = сумма align16(SIZE). Компиляция C99:
`zig cc -std=c99 -pedantic -Wall -Wextra` (gcc → zig cc → clang).
