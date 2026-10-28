#include <stdint.h>
#include "rez3ext.h"

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

_Alignas(REZ_ALIGNMENT) static char field_arena[64];
_Alignas(REZ_ALIGNMENT) static char proc_arena[64];
_Alignas(REZ_ALIGNMENT) static char slot_arena[64];
_Alignas(REZ_ALIGNMENT) static char exhausted_arena[64];
_Alignas(16) static char misaligned_storage[65];

static int32_t check_generation_exhaustion(void) {
    RezCavity exhausted = {0};
    RezCellMed mediator;
    uint32_t saved;
    void *cell;

    CHECK(rez_frame_reset(&exhausted, nullptr, exhausted_arena, 64));
    cell = rez_cell_z(&exhausted, 8);
    CHECK(cell != nullptr);
    mediator = rez_issue_cell(&exhausted, &exhausted, cell, 8);
    saved = rez_g_gen;

    rez_g_gen = 0;
    rez_decay(&exhausted);
    CHECK(rez_g_gen == 0);
    CHECK(exhausted.generation == 0);
    CHECK(rez_deref_cell(mediator) == nullptr);
    CHECK(!rez_frame_reset(&exhausted, nullptr, exhausted_arena, 64));
    CHECK(rez_deref_cell(mediator) == nullptr);

    rez_g_gen = UINT32_MAX;
    rez_decay(&exhausted);
    CHECK(rez_g_gen == 0);
    CHECK(exhausted.generation == UINT32_MAX);
    CHECK(!rez_frame_reset(&exhausted, nullptr, exhausted_arena, 64));
    rez_g_gen = saved;
    return 0;
}

int main(void) {
    RezCavity field = {0};
    RezCavity proc = {0};
    RezCavity slot = {0};
    RezCavity misaligned = {0};
    RezArena empty = {0};
    RezArena misaligned_arena = { .base = misaligned_storage + 1, .cap = 64 };
    RezCellMed med;
    uint32_t gen;
    uint32_t saved;
    void *cell;

    static_assert(REZ3EXT_ABI == 3);
    CHECK(rez_arena_alloc_z(&misaligned_arena, 1) == nullptr);
    CHECK(!rez_frame_reset(&misaligned, nullptr, misaligned_storage + 1, 64));
    CHECK(!misaligned.alive);
    CHECK(misaligned.generation == 0);
    CHECK(rez_frame_reset(&field, nullptr, field_arena, 64));
    CHECK(rez_frame_reset(&proc, &field, proc_arena, 64));
    gen = proc.generation;
    saved = rez_g_gen;
    rez_g_gen = 0;
    CHECK(!rez_frame_reset(&proc, &field, proc_arena, 64));
    CHECK(proc.generation == gen);
    CHECK(proc.alive);
    CHECK(proc.arena.base == proc_arena);
    rez_g_gen = saved;

    CHECK(rez_cav_enter(&slot, nullptr, slot_arena, 64) == &slot);
    gen = slot.generation;
    CHECK(rez_cav_enter(&slot, nullptr, slot_arena, 64) == nullptr);
    CHECK(slot.generation == gen);
    rez_decay(&slot);
    CHECK(!slot.alive);
    CHECK(slot.arena.base == nullptr);
    CHECK(rez_cav_enter(&slot, nullptr, slot_arena, 64) == &slot);
    CHECK(slot.generation != gen);
    CHECK(slot.arena.base == slot_arena);

    cell = rez_cell_z(&field, 8);
    CHECK(cell != nullptr);
    med = rez_issue_cell(&field, &field, cell, 8);
    CHECK(rez_deref_cell(med) == cell);
    CHECK(rez_cell_bounds(med, 0, 8));
    CHECK(!rez_cell_bounds(med, 1, 8));
    CHECK(!rez_cell_bounds(med, UINT64_MAX, 1));
    CHECK(rez_arena_alloc_z(&empty, 0) == nullptr);
    CHECK(rez_i64_add(INT64_MAX, 1) == INT64_MIN);
    CHECK(rez_i64_sub(INT64_MIN, 1) == INT64_MAX);
    CHECK(rez_i64_shr(-2, 1) == -1);
    CHECK(rez_i64_shl(1, 63) == INT64_MIN);
    CHECK(rez_i64_div(8, 2) == 4);
    CHECK(rez_i64_mod(8, 3) == 2);

    rez_decay(&field);
    CHECK(rez_deref_cell(med) == nullptr);
    CHECK(rez_cell_z(&field, 0) == nullptr);
    rez_decay(&proc);
    rez_decay(&slot);
    return check_generation_exhaustion();
}
