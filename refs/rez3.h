/* ============================================================================
 * REZ3.H — рантайм RESONANCE-3 для чистого C89. ~100 строк.
 * Четыре кирпича: Cavity (рамка+арена), Resonator (опора в арене),
 * Mediator ({ptr, gen}), Cascade (обычные функции + REZ_TRY).
 * Decay = cavity_leave(). Никаких зависимостей, никакого рантайма сверх этого.
 * ============================================================================
 */
#ifndef REZ3_H
#define REZ3_H

#include <stdlib.h>
#include <string.h>

/* --- арена: бамп-аллокатор, один free на полость -------------------------- */
typedef struct { char *base; size_t used, cap; } RezArena;

static void rez_arena_init(RezArena *a, size_t cap) {
    a->base = (char*)malloc(cap); a->used = 0; a->cap = cap;
}
static void *rez_arena_alloc(RezArena *a, size_t size) {
    size_t start = (a->used + 15) & ~(size_t)15;
    if (start + size > a->cap) return 0;
    a->used = start + size;
    return a->base + start;
}

/* --- рамка: две жизни. Структура живёт вне арены (имя бессмертно) --------- */
typedef struct RezCavity {
    struct RezCavity *parent;
    unsigned generation;          /* имя: монотонно, ABA закрыт */
    int alive;
    RezArena arena;               /* содержимое: смертно */
} RezCavity;

static unsigned rez_g_gen = 1;

static RezCavity *rez_enter(RezCavity *parent, size_t cap) {
    RezCavity *c = (RezCavity*)malloc(sizeof(RezCavity));
    c->parent = parent; c->generation = rez_g_gen++; c->alive = 1;
    rez_arena_init(&c->arena, cap);
    return c;
}

/* Decay: одно событие. Связи мертвы атомарно со смертью содержимого. */
static void rez_leave(RezCavity *c) {
    c->generation = rez_g_gen++;
    c->alive = 0;
    free(c->arena.base); c->arena.base = 0;
    /* struct не free: её generation — бессмертное имя для мёртвых проходов */
}

/* Resonator: опора в арене полости */
static void *rez_cell(RezCavity *c, size_t size) {
    if (!c->alive) return 0;
    return rez_arena_alloc(&c->arena, size);
}

/* --- Mediator: проход {ptr, gen} ------------------------------------------ */
typedef struct { RezCavity *target; unsigned gen; } RezMediator;

static RezMediator rez_issue(RezCavity *c) {
    RezMediator m; m.target = c; m.gen = c->generation; return m;
}

/* Мёртвый проход — NULL. Проверка обязательна: REZ_TRY раскручивает каскад */
static RezCavity *rez_deref(RezMediator m) {
    return (m.target && m.gen == m.target->generation) ? m.target : 0;
}

/* Каскад: первый мёртвый проход = атомарный abort (return из функции-каскада) */
#define REZ_TRY(expr) do { if (!(expr)) return -1; } while (0)

#endif /* REZ3_H */
