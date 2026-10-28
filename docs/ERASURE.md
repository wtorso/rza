# Листинг стирания каскада

Пример полностью находится в этом репозитории: `tests/cascade.rza`.
Воспроизвести C23:

```sh
rez3asm tests/cascade.rza --emit-c -o build/cascade.c
```

## Исходник

```asm
casc addup: a_m,b_m -> total[main]
    load  %r2, [a_m + 0]
    load  %r3, [b_m + 0]
    add   %r4, %r2, %r3
    store [a_m + 8], %r4
endc
```

Обе ячейки имеют размер 16 байт: обращения `+0` и `+8` шириной 8 байт
проверяются компилятором и не требуют runtime bounds-check.

## Актуальный вывод компилятора

```c
    /* casc addup (line 14) */
    {
        void *p_a_m = rez_deref_cell(m_a_m);
        void *p_b_m = rez_deref_cell(m_b_m);
        if (!p_a_m) {
            fprintf(stderr, "ABORT line 14: cascade addup: dead mediator a_m\n");
            goto casc_end_1;
        }
        if (!p_b_m) {
            fprintf(stderr, "ABORT line 14: cascade addup: dead mediator b_m\n");
            goto casc_end_1;
        }
        c_total = rez_cell_z(f_main, 8);
        if (!c_total) {
            fprintf(stderr, "FAULT line 14: arena overflow (out total)\n");
            exit(1);
        }
        memcpy(&r2, (char*)p_a_m + 0, 8);
        memcpy(&r3, (char*)p_b_m + 0, 8);
        r4 = rez_i64_add(r2, r3);
        memcpy((char*)p_a_m + 8, &r4, 8);
    casc_end_1:
        (void)0;
    }
```

Диагностические блоки переносятся по строкам. Все листинги valid fixtures
проходят проверку: ни одной строки длиннее 100 колонок.

## Что стирается

- Владельцы и поколения проверяются один раз через `rez_deref_cell` на входе.
- Первый мёртвый медиатор ведёт на общий `casc_end_1`: тело не выполняется.
- Постоянные смещения известны чекеру. Внутри остаются только `memcpy`.
- `add` вызывает `rez_i64_add`: wrapping i64 определён и не зависит от
  signed overflow в C.
- OUT создаётся после успешной проверки входов, поэтому abort не оставляет
  новую ячейку или частичный результат.

Вычисляемое смещение нельзя проверить один раз на входе: перед таким доступом
компилятор оставляет `rez_cell_bounds`. Стирание применяется только тогда,
когда безопасность доказана статически.
