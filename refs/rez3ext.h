/* ============================================================================
 * REZ3EXT.H — безопасное расширение рантайма RESONANCE-3 для REZ3-ASM.
 * rez3.h заморожен: новые проверки и типы находятся только здесь.
 * ASM-слой использует C99; всё static, один TU на программу.
 * ============================================================================
 */
#ifndef REZ3EXT_H
#define REZ3EXT_H

#include <stdint.h>
#include "rez3.h"

/* RezCellMed передаётся хосту по значению: все TU пересобираются вместе. */
#define REZ3EXT_ABI 2
static void rez_decay(RezCavity *c) {
    if (!c) return;
    c->generation = rez_g_gen++;
    c->alive = 0;
    c->arena.base = 0;
    c->arena.used = 0;
    c->arena.cap = 0;
}

/* Текущий владелец задаёт права; домашний владелец задаёт жизнь памяти. */
typedef struct {
    void *cell;
    RezCavity *owner;
    RezCavity *home;
    unsigned gen;
    unsigned home_gen;
    size_t size;
} RezCellMed;

static void *rez_arena_alloc_z(RezArena *a, size_t size) {
    size_t start;
    if (!a->base) return 0;
    if (a->used > (size_t)-1 - 15) return 0;
    start = (a->used + 15) & ~(size_t)15;
    if (start > a->cap || size > a->cap - start) return 0;
    a->used = start + size;
    return a->base + start;
}

static void *rez_cell_z(RezCavity *c, size_t size) {
    void *p;
    if (!c || !c->alive) return 0;
    p = rez_arena_alloc_z(&c->arena, size);
    if (p) memset(p, 0, size);
    return p;
}

static RezCellMed rez_issue_cell(RezCavity *owner, RezCavity *home,
                                 void *cell, size_t size) {
    RezCellMed m;
    m.cell = cell;
    m.owner = owner;
    m.home = home;
    m.gen = owner ? owner->generation : 0;
    m.home_gen = home ? home->generation : 0;
    m.size = size;
    return m;
}

static void *rez_deref_cell(RezCellMed m) {
    if (!m.cell || !m.owner || !m.home) return 0;
    if (!m.owner->alive || !m.home->alive) return 0;
    if (m.gen != m.owner->generation) return 0;
    if (m.home_gen != m.home->generation) return 0;
    return m.cell;
}

static int rez_cell_bounds(RezCellMed m, size_t offset, size_t width) {
    return offset <= m.size && width <= m.size - offset;
}

/* Рамка и арена принадлежат вызывающему коду и не выделяются из кучи. */
static int rez_frame_reset(RezCavity *c, RezCavity *parent,
                           char *base, size_t cap) {
    if (!c || !base || cap == 0 || rez_g_gen == 0) return 0;
    c->parent = parent;
    c->generation = rez_g_gen++;
    c->alive = 1;
    c->arena.base = base;
    c->arena.used = 0;
    c->arena.cap = cap;
    return 1;
}

static RezCavity *rez_cav_enter(RezCavity *c, RezCavity *parent,
                                char *base, size_t cap) {
    if (!c || c->alive) return 0;
    if (!rez_frame_reset(c, parent, base, cap)) return 0;
    return c;
}

static uint64_t rez_i64_bits(int64_t value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static int64_t rez_i64_value(uint64_t bits) {
    int64_t value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static int64_t rez_i64_add(int64_t a, int64_t b) {
    return rez_i64_value(rez_i64_bits(a) + rez_i64_bits(b));
}

static int64_t rez_i64_sub(int64_t a, int64_t b) {
    return rez_i64_value(rez_i64_bits(a) - rez_i64_bits(b));
}

static int64_t rez_i64_mul(int64_t a, int64_t b) {
    return rez_i64_value(rez_i64_bits(a) * rez_i64_bits(b));
}

static int64_t rez_i64_div(int64_t a, int64_t b) { return a / b; }
static int64_t rez_i64_mod(int64_t a, int64_t b) { return a % b; }

/* Диапазон проверяет вызывающий код: 0 <= shift < 64. */
static int64_t rez_i64_shl(int64_t value, int64_t shift) {
    return rez_i64_value(rez_i64_bits(value) << (unsigned)shift);
}

static int64_t rez_i64_shr(int64_t value, int64_t shift) {
    uint64_t bits = rez_i64_bits(value);
    if (shift == 0) return value;
    bits >>= (unsigned)shift;
    if (value < 0) bits |= ~(uint64_t)0 << (64 - (unsigned)shift);
    return rez_i64_value(bits);
}

#endif /* REZ3EXT_H */
