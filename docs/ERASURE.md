# Листинг стирания: боевой casc в bond (review P8)

Каскад `snap` — из боевого пути игры: `proc snap_stats` в
`bond/arch/bond.rza` вызывается хостом в конце партии (smoke: строка
`SNAP OK`) и атомарно снимает итоги из ячеек `cnt` и `phys`. Семантика
каскада: оба медиатора живы — или не написано ни байта.

## Исходник (.rza)

```
proc snap_stats:
    casc snap: cnt_m, phys_m -> snapout[mission]
        load  %r0, [phys_m + 0]      ; x
        load  %r1, [phys_m + 8]      ; y
        store [cnt_m + 96], %r0      ; cnt[12] = x
        store [cnt_m + 104], %r1     ; cnt[13] = y
        load  %r0, [cnt_m + 0]       ; energy
        load  %r1, [cnt_m + 8]       ; kills
        store [cnt_m + 112], %r0     ; cnt[14] = energy
        store [cnt_m + 120], %r1     ; cnt[15] = kills
    endc
    ret
```

## Стирается в (реальный вывод `rez3asm --emit-lib`, bond build/bond_arch.c)

```c
/* casc snap (line 65) */
{
    void *p_cnt_m = rez_deref_cell(m_cnt_m);
    void *p_phys_m = rez_deref_cell(m_phys_m);
    if (!p_cnt_m) { fprintf(stderr, "ABORT line 65: cascade snap: dead mediator cnt_m\n"); goto casc_end_1; }
    if (!p_phys_m) { fprintf(stderr, "ABORT line 65: cascade snap: dead mediator phys_m\n"); goto casc_end_1; }
    c_snap_stats_snapout = rez_cell_z(f_mission_begin_mission, 8);
    if (!c_snap_stats_snapout) { fprintf(stderr, "FAULT line 65: arena overflow (out snapout)\n"); exit(1); }
    r0 = *(int64_t*)((char*)p_phys_m + 0);
    r1 = *(int64_t*)((char*)p_phys_m + 8);
    *(int64_t*)((char*)p_cnt_m + 96) = r0;
    *(int64_t*)((char*)p_cnt_m + 104) = r1;
    r0 = *(int64_t*)((char*)p_cnt_m + 0);
    r1 = *(int64_t*)((char*)p_cnt_m + 8);
    *(int64_t*)((char*)p_cnt_m + 112) = r0;
    *(int64_t*)((char*)p_cnt_m + 120) = r1;
casc_end_1:
    (void)0;
}
```

## Что видно

- **Проверка поколений — один раз на входе** [I3]: два `rez_deref_cell`
  и два `goto casc_end_1` (атомарный abort: тело пропускается целиком).
- **Тело стёрто до голой арифметики указателей**: восемь обращений —
  восемь `*(int64_t*)((char*)p + off)` без повторных проверок живости.
  Это и есть стирание: цена безопасности не зависит от длины тела.
- **OUT** (`snapout`) — новая ячейка в рамке `mission` (AUDIT-1/#6);
  нуле-инициализирована (`rez_cell_z`, AUDIT-6).
- Сравнение с внекaskадным кодом: обычный `load` вне casc несёт свой
  `rez_deref_cell` на КАЖДОЕ обращение (см. любой `phys_step` рядом в
  том же файле) — каскад окупается с третьего обращения.

Почему каскад только здесь, а не в горячем цикле врагов: casc — конструкт
атомарности батча, а не перфреймового цикла; «abort ≠ пропустить кадр»
(rez3-asm/README.md, «Каскады в боевом коде»). Снимок итогов — батч по
смыслу: частичный снимок недопустим.
