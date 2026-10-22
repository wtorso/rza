/* ============================================================================
 * REZ3EXT.H — расширение рантайма RESONANCE-3 для ассемблерного слоя (.rza).
 * rez3.h не меняется (AUDIT-1/#4): здесь только НОВЫЕ сущности.
 *
 *   - RezCellMed: медиатор на ЯЧЕЙКУ {cell, owner, gen}. Медиатор rez3.h
 *     адресует рамку целиком; ассемблеру нужна адресация ячейки.
 *   - rez_issue_cell / rez_deref_cell: выдача и распечатка. Мёртвый проход —
 *     NULL (fault на стороне потребителя, не UB).
 *   - rez_decay: синоним rez_leave (таблица отображения слоёв, AUDIT-2/п.1).
 *   - rez_frame_reset: re-enter для статических рамок процедур: та же
 *     структура RezCavity, новое поколение (анти-ABA), свежая арена.
 *
 * Стиль — как rez3.h: C89-совместимый, всё static, один TU на программу
 * (rez_g_gen — static в rez3.h, поэтому оба заголовка включаются в один .c).
 * ============================================================================
 */
#ifndef REZ3EXT_H
#define REZ3EXT_H

#include "rez3.h"

/* ABI-стамп границы lib-режима: RezCellMed уходит в хост-TU по значению.
 * Меняешь раскладку RezCellMed или сигнатуры rza_* — инкрементируй;
 * хост сверяет rza_rez3ext_abi (SPEC .rza §9, review-audit D1). */
#define REZ3EXT_ABI 1

/* ASM: decay; IR: leave; C: rez_leave — одно событие (AUDIT-2/п.1) */
#define rez_decay rez_leave

/* Медиатор на ячейку: {указатель, рамка-владелец, поколение} (AUDIT-1/#4) */
typedef struct { void *cell; RezCavity *owner; unsigned gen; } RezCellMed;

/* AUDIT-6 (SPEC .rza §2): память ячеек ASM-слоя нуле-инициализирована.
 * rez3.h не меняется (AGENTS.md) — обнуление на границе выдачи ячейки.
 * Прецедент: malloc-мусор в незаписанной ячейке cnt давал
 * недетерминированный smoke (bond, rides). */
static void *rez_cell_z(RezCavity *c, size_t size) {
    void *p = rez_cell(c, size);
    if (p) memset(p, 0, size);
    return p;
}

/* Выдача прохода: поколение фиксируется на момент выдачи */
static RezCellMed rez_issue_cell(RezCavity *owner, void *cell) {
    RezCellMed m;
    m.cell = cell; m.owner = owner; m.gen = owner->generation;
    return m;
}

/* Распечатка: ячейка, если владелец жив и поколение совпало; иначе 0 */
static void *rez_deref_cell(RezCellMed m) {
    return (m.cell && m.owner && m.owner->alive
            && m.gen == m.owner->generation) ? m.cell : 0;
}

/* Re-enter рамки процедуры: старая арена освобождается, поколение новое.   */
/* Статическая RezCavity нуле-инициализирована: первый вызов безопасен.     */
static void rez_frame_reset(RezCavity *c, RezCavity *parent, size_t cap) {
    if (c->arena.base) free(c->arena.base);
    c->parent = parent;
    c->generation = rez_g_gen++;
    c->alive = 1;
    rez_arena_init(&c->arena, cap);
}

#endif /* REZ3EXT_H */
