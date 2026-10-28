# RZA — RESONANCE-3 и REZ3-ASM

## Проверка

`bash run_tests.sh` → 102/102 PASS, exit 0. Включает C23 reference, static shop,
runtime boundaries, LSP smoke, C3 unit tests и fuzz. Компилятор C и C3 собирается
со строгими warnings; generated C проверяется на строки не длиннее 100.

## Стек

- Транспайлер: `rez3asm.c3` + `lsp_server.c3` (C3 0.8.5).
- `build_compiler.sh` — атомарная сборка с уникальными временными именами.
- C23: `zig cc`, fallback gcc/clang. Ноль warnings, `-Werror`, UBSan.
- `refs/rez3.h` — общее static-ядро; `refs/rez3ext.h` — медиаторы и i64.
- `editors/vscode` — submodule `../rza-vscode`.

## Документы

- `SPEC.md` — норма языка.
- `refs/RZ3-MANUAL.md` — эталон IR; семантику не менять.
- `docs/RESONANCE-3-SPEC.md` — модель.
- `docs/GUIDE.md`, `ERASURE.md`, `PERF.md` — учебник, стирание, цена.
- `.kimi-code/skills/` — правила кода и тестов.

## Нормы

- Модель п.0 неизменяема: 4 кирпича, 6 имён, 4 инварианта.
- Tiger Style: безопасность, явные bounds, fixed-width типы, assertions,
  функции до 70 строк, строки до 100 колонок, имена с единицами измерения.
- После инициализации — только fixed storage и никаких heap-вызовов.
- Ожидаемые значения тестов — с выводом, не магические константы.
- Конфликт с моделью записывать в `SPEC.md` §9 со ссылкой AUDIT-x/#N.
- Без TODO и заглушек. Каждая ветка чекера покрыта тестом.
- `REZ3EXT_ABI = 3`; менять публичную layout только с новой версией ABI.

## Границы модели

raise — static-only; домашняя рамка ограничивает жизнь памяти.
Load по статически мёртвому медиатору — runtime-fault. Доступ вне ячейки —
static violation для константы и runtime-fault для регистра. acasc синхронен.
OUT каскада = 8 байт. Опасные div/mod и сдвиги — runtime-fault. См. `SPEC.md` §9.
