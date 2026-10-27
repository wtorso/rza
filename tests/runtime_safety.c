#include <stdint.h>
#include <stdlib.h>

static int heap_calls;
static void *test_malloc(size_t size) {
    heap_calls++;
    (void)size;
    return NULL;
}
static void test_free(void *p) {
    heap_calls++;
    (void)p;
}
#define malloc test_malloc
#define free test_free
#include "rez3ext.h"
#undef malloc
#undef free

#define CHECK(cond) do { if (!(cond)) return __LINE__; } while (0)

int main(void) {
    RezCavity field = {0};
    RezCavity proc = {0};
    RezCavity slot = {0};
    RezArena empty = {0};
    char field_arena[64];
    char proc_arena[64];
    char slot_arena[64];
    RezCellMed med;
    unsigned gen;
    unsigned saved;
    void *cell;

    (void)&rez_arena_alloc_z; (void)&rez_cell_z; (void)&rez_issue_cell;
    (void)&rez_deref_cell; (void)&rez_cell_bounds; (void)&rez_frame_reset;
    (void)&rez_cav_enter; (void)&rez_i64_add; (void)&rez_i64_sub;
    (void)&rez_i64_mul; (void)&rez_i64_div; (void)&rez_i64_mod;
    (void)&rez_i64_shl; (void)&rez_i64_shr;
    (void)&test_malloc; (void)&test_free;

    CHECK(rez_frame_reset(&field, NULL, field_arena, 64));
    CHECK(rez_frame_reset(&proc, &field, proc_arena, 64));
    gen = proc.generation;
    saved = rez_g_gen;
    rez_g_gen = 0;
    CHECK(!rez_frame_reset(&proc, &field, proc_arena, 64));
    CHECK(proc.generation == gen && proc.alive && proc.arena.base == proc_arena);
    rez_g_gen = saved;

    CHECK(rez_cav_enter(&slot, NULL, slot_arena, 64) == &slot);
    gen = slot.generation;
    CHECK(rez_cav_enter(&slot, NULL, slot_arena, 64) == NULL);
    CHECK(slot.generation == gen);
    rez_decay(&slot);
    CHECK(!slot.alive && slot.arena.base == NULL);
    CHECK(rez_cav_enter(&slot, NULL, slot_arena, 64) == &slot);
    CHECK(slot.generation != gen && slot.arena.base == slot_arena);

    cell = rez_cell_z(&field, 8);
    CHECK(cell != NULL);
    med = rez_issue_cell(&field, &field, cell, 8);
    CHECK(rez_deref_cell(med) == cell);
    CHECK(rez_cell_bounds(med, 0, 8));
    CHECK(!rez_cell_bounds(med, 1, 8));
    CHECK(!rez_cell_bounds(med, (size_t)-1, 1));
    CHECK(rez_arena_alloc_z(&empty, 0) == NULL);
    CHECK(rez_i64_add(INT64_MAX, 1) == INT64_MIN);
    CHECK(rez_i64_sub(INT64_MIN, 1) == INT64_MAX);
    CHECK(rez_i64_shr(-2, 1) == -1);
    CHECK(rez_i64_shl(1, 63) == INT64_MIN);
    CHECK(rez_i64_div(8, 2) == 4 && rez_i64_mod(8, 3) == 2);

    rez_decay(&field);
    CHECK(rez_deref_cell(med) == NULL);
    CHECK(rez_cell_z(&field, 0) == NULL);
    rez_decay(&proc);
    rez_decay(&slot);
    CHECK(heap_calls == 0);
    return 0;
}
