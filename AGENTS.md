# RZA — RESONANCE-3 и REZ3-ASM

## Проверка

`bash run_tests.sh` → 75/75 PASS, exit 0. Включает LSP smoke и fuzz.

## Стек

- Транспайлер: `rez3asm.c3` + `lsp_server.c3` (C3 0.8.5).
- C99: `zig cc`, fallback gcc/clang. Ноль warnings.
- `refs/rez3.h` заморожен. Расширения — новыми сущностями в `refs/rez3ext.h`.
- `editors/vscode` — submodule `../rza-vscode`.
- `gba/` — эксперимент, вне общего прогона.

## Документы

- `SPEC.md` — норма языка.
- `refs/RZ3-MANUAL.md` — эталон IR; не менять.
- `docs/RESONANCE-3-SPEC.md` — модель.
- `docs/GUIDE.md`, `ERASURE.md`, `PERF.md` — учебник, стирание, цена.
- `.kimi-code/skills/` — правила кода и тестов.

## Нормы

- Модель п.0 неизменяема: 4 кирпича, 6 имён, 4 инварианта.
- Ожидаемые значения тестов — с выводом, не магические константы.
- Конфликт с моделью записывать в `SPEC.md` §9 со ссылкой AUDIT-x/#N.
- Без TODO и заглушек. Каждая ветка чекера покрыта тестом.

## Границы модели

raise — static-only. Load по статически мёртвому медиатору — runtime-fault.
acasc синхронен. OUT каскада = 8 байт. div/mod на нуле — UB. См. `SPEC.md` §9.
