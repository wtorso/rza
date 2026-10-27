#include <stdint.h>
#include <stdlib.h>

static int fail_after = -1;
static void *test_malloc(size_t size) {
    if (fail_after == 0) return NULL;
    if (fail_after > 0) fail_after--;
    return malloc(size);
}
#define malloc test_malloc
#include "rez3ext.h"
#undef malloc

#define CHECK(cond) do { if (!(cond)) return __LINE__; } while (0)

int main(void) {
    RezCavity proc = {0};
    RezArena empty = {0};
    RezCavity *field;
    RezCavity *slot = NULL;
    RezCellMed med;
    char *arena;
    unsigned gen;
    void *cell;

    (void)&rez_arena_init; (void)&rez_arena_alloc; (void)&rez_enter;
    (void)&rez_cell; (void)&rez_arena_alloc_z; (void)&rez_issue;
    (void)&rez_deref; (void)&rez_cell_z; (void)&rez_issue_cell;
    (void)&rez_deref_cell; (void)&rez_cell_bounds; (void)&rez_frame_reset;
    (void)&rez_cav_enter; (void)&rez_leave; (void)&rez_i64_add;
    (void)&rez_i64_sub; (void)&rez_i64_mul; (void)&rez_i64_div;
    (void)&rez_i64_mod; (void)&rez_i64_shl; (void)&rez_i64_shr;

    fail_after = 0;
    CHECK(rez_enter_checked(NULL, 64) == NULL);
    fail_after = 1;
    CHECK(rez_enter_checked(NULL, 64) == NULL);
    CHECK(!rez_frame_reset(&proc, NULL, 64));

    fail_after = -1;
    field = rez_enter_checked(NULL, 64);
    CHECK(field != NULL);
    CHECK(rez_frame_reset(&proc, field, 64));
    arena = proc.arena.base;
    gen = proc.generation;
    fail_after = 0;
    CHECK(!rez_frame_reset(&proc, field, 64));
    CHECK(proc.arena.base == arena && proc.generation == gen && proc.alive);
    fail_after = -1;

    CHECK(rez_cav_enter(&slot, NULL, 64) == slot && slot != NULL);
    gen = slot->generation;
    CHECK(rez_cav_enter(&slot, NULL, 64) == NULL);
    CHECK(slot->generation == gen);
    rez_leave(slot);
    CHECK(rez_cav_enter(&slot, NULL, 64) == slot);
    CHECK(slot->generation != gen);

    cell = rez_cell_z(field, 8);
    CHECK(cell != NULL);
    med = rez_issue_cell(field, field, cell, 8);
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

    rez_leave(field);
    CHECK(rez_deref_cell(med) == NULL);
    CHECK(rez_cell_z(field, 0) == NULL);
    rez_leave(&proc);
    rez_leave(slot);
    rez_g_gen = 0;
    CHECK(rez_enter_checked(NULL, 64) == NULL);
    CHECK(!rez_frame_reset(&proc, NULL, 64));
    CHECK(rez_cav_enter(&slot, NULL, 64) == NULL);
    rez_g_gen = 1;
    free(field);
    free(slot);
    return 0;
}
