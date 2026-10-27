# rza/gba — .rza на Game Boy Advance (sly как отладчик)

Путь A: **.rza → C99 → GBA ROM → sly-debugger**. Новый бэкенд не нужен.
GBA использует ARM7TDMI; i64 реализуется компилятором над 32-битными
регистрами. `zig cc` собирает цель `arm-freestanding-eabi`.
Путь B (65C816/SNES) отложен: i64 на 16-битном CPU требует больше
софт-арифметики.

## Конвейер

```sh
cd rza/gba
./build.sh ../tests/fib.rza out/fib.gba     # .rza → C99 → ARM → .gba
sly-debugger out/fib.gba                     # или перетащить в окно sly
```

- `crt0.c` — заголовок GBA (entry, логотип Nintendo, поля, checksum),
  `_start`: стек IWRAM, `__crt_init` (.data ROM→EWRAM, .bss→0 — без этого
  глобали пишутся в ROM, no-op; прецедент: fib «не работал»), `main`.
- `harness.c` — libc-заглушки: `printf`/`fprintf` пишут i64-аргументы в
  лог EWRAM `0x02000000` (i64 за записью), `exit` — маркер
  `0x0DEC0DE000000000|code`, `malloc` — bump по EWRAM с 0x02010000.
- `gba.ld` — заголовок/код в ROM (0x08000000), .data/.bss в EWRAM
  (0x02002000, копия/чистка в crt0), unwind-мусор отброшен.
- `include/` — заглушки stdio/stdlib/string (freestanding: настоящих нет).

## Проверка результата в sly

Тест пишет значения в лог: `[0]=magic 0x1A5A525A31 (после exit)`,
`[1..]=по одному i64 на printf`. В sly: Memory → CPU Bus → go to
`02000000`. Прецедент: fib.gba → `[1] = 0x37 = 55 = F(10)` ✓ (скриншот
в истории сессии 2026-10-21).

## Границы

- Лог — 500 записей i64 (4K области EWRAM). Длинные трассы — расширить.
- exit() вызывается только по fault-путям; нормальное завершение = main
  возвращается, PC встаёт в halt-петлю — лог при этом уже полон.
- GBA-цель — для отладки/доказательства переносимости, не платформа игры
  (bond — Windows/C3+raylib; SNES-игра — только если решим иначе).
