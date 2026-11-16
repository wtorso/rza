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

static RzaResult async_succeed(void *context) {
    (*(int *)context)++;
    return (RzaResult){ .code = RZA_OK };
}

static RzaResult async_abort(void *context) {
    (void)context;
    return (RzaResult){ .code = RZA_ABORT };
}

static RzaResult async_fault(void *context) {
    (void)context;
    return (RzaResult){ .code = RZA_FAULT_DIVISION };
}

static int check_async_queue(void) {
    RezAsyncQueue queue = {0};
    RzaAwaitResult drained;
    int completed = 0;
    bool pending = false;
    bool other_pending = false;
    CHECK(rez_async_enqueue(&queue, async_succeed, &completed, &pending));
    CHECK(rez_async_enqueue(&queue, async_abort, &completed, &other_pending));
    CHECK(queue.count == 2);
    drained = rez_async_drain(&queue);
    CHECK(drained.completed == 1 && drained.result.code == RZA_OK);
    CHECK(completed == 1 && queue.count == 0);
    drained = rez_async_drain(&queue);
    CHECK(drained.completed == 0 && drained.result.code == RZA_OK);
    for (uint32_t i = 0; i < REZ_ASYNC_MAX; i++) {
        bool slot_pending = false;
        CHECK(rez_async_enqueue(&queue, async_succeed, &completed, &slot_pending));
    }
    CHECK(!rez_async_enqueue(&queue, async_succeed, &completed, &pending));
    drained = rez_async_drain(&queue);
    CHECK(drained.completed == REZ_ASYNC_MAX && drained.result.code == RZA_OK);

    completed = 0;
    pending = false;
    other_pending = false;
    bool last_pending = false;
    CHECK(rez_async_enqueue(&queue, async_succeed, &completed, &pending));
    CHECK(rez_async_enqueue(&queue, async_fault, &completed, &other_pending));
    CHECK(rez_async_enqueue(&queue, async_succeed, &completed, &last_pending));
    drained = rez_async_drain(&queue);
    CHECK(drained.completed == 1 && drained.result.code == RZA_FAULT_DIVISION);
    CHECK(completed == 1 && queue.count == 0 && queue.head == 0);
    for (uint32_t i = 0; i < REZ_ASYNC_MAX; i++) CHECK(queue.tasks[i].run == nullptr);
    return 0;
}

static int32_t check_checked_arithmetic(void) {
    int64_t checked;
    CHECK(!rez_i64_cadd(INT64_MAX, 0, &checked) && checked == INT64_MAX);
    CHECK(rez_i64_cadd(INT64_MAX, 1, &checked));
    CHECK(rez_i64_cadd(INT64_MIN, -1, &checked));
    CHECK(!rez_i64_csub(INT64_MIN, 0, &checked) && checked == INT64_MIN);
    CHECK(rez_i64_csub(INT64_MIN, 1, &checked));
    CHECK(rez_i64_csub(INT64_MAX, -1, &checked));
    CHECK(!rez_i64_cmul(INT64_MIN, 1, &checked) && checked == INT64_MIN);
    CHECK(!rez_i64_cmul(-1, -1, &checked) && checked == 1);
    CHECK(rez_i64_cmul(INT64_MIN, -1, &checked));
    CHECK(rez_i64_cmul(INT64_MAX, 2, &checked));
    return 0;
}

static int32_t check_forged_view_metadata(RezCellMed med) {
    RezCellMed view = {0};
    RezCellMed forged = med;
    forged.owner = (RezCavity *)(uintptr_t)1;
    CHECK(!rez_view_cell(forged, 0, 1, 1, &view));
    forged = med;
    forged.home = (RezCavity *)(uintptr_t)3;
    CHECK(!rez_view_cell(forged, 0, 1, 1, &view));
    forged = med;
    forged.allocation = (uint32_t *)(uintptr_t)1;
    forged.allocation_gen = 1;
    CHECK(!rez_view_cell(forged, 0, 1, 1, &view));
    forged = med;
    forged.allocation_gen = 1;
    CHECK(!rez_view_cell(forged, 0, 1, 1, &view));
    forged = med;
    forged.cell = (void *)UINTPTR_MAX;
    CHECK(!rez_view_cell(forged, 1, 1, 1, &view));
    return 0;
}

static int32_t check_allocation_generation(RezCavity *field, void *cell) {
    uint32_t generation = 1;
    RezCellMed view = {0};
    RezCellMed current = rez_issue_cell_versioned(field, field, cell, 8, &generation);
    RezCellMed stale = current;
    CHECK(current.allocation == &generation && current.allocation_gen == 1);
    CHECK(rez_deref_cell(current) == cell);
    generation++;
    CHECK(rez_deref_cell(stale) == nullptr);
    CHECK(!rez_view_cell(stale, 0, 1, 1, &view));
    CHECK(view.cell == nullptr && view.size == 0);
    current = rez_issue_cell_versioned(field, field, cell, 8, &generation);
    CHECK(rez_deref_cell(current) == cell);
    CHECK(rez_view_cell(current, 0, 8, 1, &view));
    CHECK(view.allocation == &generation && view.allocation_gen == generation);
    return 0;
}

static int32_t check_view_ranges(RezCellMed med) {
    RezCellMed view = {0};
    RezCellMed nested = {0};
    RezCellMed invalid = { .size = 77 };
    char *base = med.cell;

    CHECK(rez_view_cell(med, 1, 6, 1, &view));
    CHECK(view.cell == base + 1 && view.size == 6);
    CHECK(view.owner == med.owner && view.home == med.home);
    CHECK(view.gen == med.gen && view.home_gen == med.home_gen);
    CHECK(rez_view_cell(view, 2, 3, 1, &nested));
    CHECK(nested.cell == base + 3 && nested.size == 3);
    CHECK(rez_view_cell(med, 8, 0, 1, &view));
    CHECK(view.cell == base + 8 && view.size == 0);
    CHECK(rez_deref_cell(view) == base + 8);
    CHECK(rez_cell_bounds(view, 0, 0));
    CHECK(!rez_cell_bounds(view, 0, 1));
    CHECK(!rez_cell_bounds(view, UINT64_MAX, 1));
    CHECK(rez_view_cell(med, 0, 1, 8, &view));
    CHECK(view.cell == base && view.size == 8);
    CHECK(rez_view_cell(med, 1, 0, 8, &view));
    CHECK(view.cell == base + 8 && view.size == 0);

    CHECK(!rez_view_cell(med, 9, 0, 1, &invalid));
    CHECK(invalid.cell == nullptr && invalid.size == 0);
    invalid = (RezCellMed){ .size = 77 };
    CHECK(!rez_view_cell(med, 0, 9, 1, &invalid));
    CHECK(invalid.cell == nullptr && invalid.size == 0);
    CHECK(!rez_view_cell(med, 1, UINT64_MAX, 1, &invalid));
    CHECK(!rez_view_cell(med, UINT64_MAX, 1, 1, &invalid));
    CHECK(!rez_view_cell(med, INT64_MAX, 1, 1, &invalid));
    CHECK(!rez_view_cell(med, 0, 1, 0, &invalid));
    CHECK(!rez_view_cell(med, 0, 1, UINT64_MAX, &invalid));
    CHECK(!rez_view_cell(med, 0, 1, 1, nullptr));
    CHECK(!rez_view_cell((RezCellMed){0}, 0, 1, 1, &invalid));
    CHECK(invalid.cell == nullptr && invalid.size == 0);

    CHECK(rez_view_cell(med, 1, 6, 1, &view));
    CHECK(!rez_view_cell(view, 0, 1, 4, &invalid));
    CHECK(invalid.cell == nullptr && invalid.size == 0);
    return 0;
}

static int32_t check_crc32c(void) {
    uint64_t word = UINT64_C(0x3837363534333231);
    uint64_t expected = UINT64_C(1619493018) ^ UINT32_MAX;
    CHECK(rez_crc32c_u64_fallback(UINT32_MAX, word) == expected);
    CHECK(rez_crc32c_u64(UINT32_MAX, word) == expected);
    return 0;
}

int main(void) {
    RezCavity field = {0}, proc = {0}, slot = {0}, misaligned = {0};
    RezArena empty = {0};
    RezArena misaligned_arena = { .base = misaligned_storage + 1, .cap = 64 };
    RezCellMed med;
    uint32_t gen, saved;
    void *cell;

    static_assert(REZ3EXT_ABI == 5);
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
    CHECK(rez_i64_ushr(-1, 0) == -1);
    CHECK(rez_i64_ushr(-1, 1) == INT64_MAX);
    CHECK(rez_i64_ushr(INT64_MIN, 63) == 1);
    CHECK(rez_i64_shl(1, 63) == INT64_MIN);
    CHECK(rez_i64_div(8, 2) == 4);
    CHECK(rez_i64_mod(8, 3) == 2);
    CHECK(check_checked_arithmetic() == 0);
    CHECK(check_crc32c() == 0);
    CHECK(check_view_ranges(med) == 0);
    CHECK(check_allocation_generation(&field, cell) == 0);
    CHECK(check_forged_view_metadata(med) == 0);

    rez_decay(&field);
    CHECK(rez_deref_cell(med) == nullptr);
    CHECK(!rez_view_cell(med, 0, 1, 1, &med));
    CHECK(med.cell == nullptr && med.size == 0);
    CHECK(rez_cell_z(&field, 0) == nullptr);
    rez_decay(&proc);
    rez_decay(&slot);
    CHECK(check_async_queue() == 0);
    return check_generation_exhaustion();
}
