/*
 * RESONANCE-3 fixed-storage runtime core.
 * C23: no heap allocation; every arena belongs to its caller.
 */
#ifndef REZ3_H
#define REZ3_H

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define REZ_ALIGNMENT 16ULL

typedef struct {
    char *base;
    uint64_t used;
    uint64_t cap;
} RezArena;

typedef struct RezCavity {
    struct RezCavity *parent;
    uint32_t generation;
    bool alive;
    RezArena arena;
} RezCavity;

static uint32_t rez_g_gen = 1;

static_assert(REZ_ALIGNMENT == 16);
static_assert(sizeof(uint32_t) == 4);
static_assert(sizeof(uint64_t) == 8);

[[maybe_unused]] static void rez_decay(RezCavity *cavity) {
    if (cavity == nullptr) return;
    assert(cavity->arena.used <= cavity->arena.cap);
    cavity->alive = false;
    cavity->generation = rez_g_gen;
    if (rez_g_gen != 0) rez_g_gen++;
    cavity->arena.base = nullptr;
    cavity->arena.used = 0;
    cavity->arena.cap = 0;
    assert(!cavity->alive);
    assert(cavity->arena.base == nullptr);
}

[[maybe_unused]] static bool rez_frame_reset(
    RezCavity *cavity,
    RezCavity *parent,
    char *base,
    uint64_t cap
) {
    if (cavity == nullptr) return false;
    if (base == nullptr) return false;
    if ((uintptr_t)base % REZ_ALIGNMENT != 0) return false;
    if (cap == 0) return false;
    if (rez_g_gen == 0) return false;
    assert(cavity != parent);
    cavity->parent = parent;
    cavity->generation = rez_g_gen++;
    cavity->alive = true;
    cavity->arena.base = base;
    cavity->arena.used = 0;
    cavity->arena.cap = cap;
    assert(cavity->generation != 0);
    assert(cavity->arena.used == 0);
    return true;
}

[[maybe_unused]] static RezCavity *rez_cav_enter(
    RezCavity *cavity,
    RezCavity *parent,
    char *base,
    uint64_t cap
) {
    if (cavity == nullptr) return nullptr;
    if (cavity->alive) return nullptr;
    if (!rez_frame_reset(cavity, parent, base, cap)) return nullptr;
    assert(cavity->alive);
    assert(cavity->arena.base == base);
    return cavity;
}

[[maybe_unused]] static void *rez_arena_alloc_z(RezArena *arena, uint64_t size) {
    uint64_t start;
    if (arena == nullptr) return nullptr;
    if (arena->base == nullptr) return nullptr;
    if ((uintptr_t)arena->base % REZ_ALIGNMENT != 0) return nullptr;
    assert(arena->used <= arena->cap);
    if (arena->used > UINT64_MAX - (REZ_ALIGNMENT - 1)) return nullptr;
    start = (arena->used + REZ_ALIGNMENT - 1) & ~(REZ_ALIGNMENT - 1);
    if (start > arena->cap) return nullptr;
    if (size > arena->cap - start) return nullptr;
    arena->used = start + size;
    assert(arena->used <= arena->cap);
    return arena->base + start;
}

[[maybe_unused]] static void *rez_cell_z(RezCavity *cavity, uint64_t size) {
    void *cell;
    if (cavity == nullptr) return nullptr;
    if (!cavity->alive) return nullptr;
    if (size > SIZE_MAX) return nullptr;
    cell = rez_arena_alloc_z(&cavity->arena, size);
    if (cell != nullptr) memset(cell, 0, (size_t)size);
    if (cell != nullptr) assert(cavity->alive);
    return cell;
}

#endif
