#include <stdint.h>
#include "rez3ext.h"

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

_Alignas(16) static char field_arena[64];
_Alignas(16) static char home_arena[64];
_Alignas(16) static char misaligned_storage[65];

int main(void) {
    RezCavity field = {0};
    RezCavity home = {0};
    RezCavity invalid = {0};
    RezCellMed med = {0};
    RezArena misaligned = { .base = misaligned_storage + 1, .cap = 64 };
    void *cell;

    CHECK(rez_deref_cell(med) == nullptr);
    CHECK(rez_frame_reset(&field, nullptr, field_arena, 64));
    CHECK(rez_frame_reset(&home, nullptr, home_arena, 64));
    cell = rez_cell_z(&field, 8);
    CHECK(cell != nullptr);
    med = rez_issue_cell(&field, &home, cell, 8);
    CHECK(rez_issue_cell(&field, &home, cell, 8).cell == cell);
    CHECK(rez_deref_cell(med) == cell);
    CHECK(rez_cell_bounds(med, 0, 8));

    med.owner = nullptr;
    CHECK(rez_deref_cell(med) == nullptr);
    med = rez_issue_cell(&field, &home, cell, 8);
    med.home = nullptr;
    CHECK(rez_deref_cell(med) == nullptr);
    med = rez_issue_cell(&field, &home, cell, 8);
    med.cell = nullptr;
    CHECK(rez_deref_cell(med) == nullptr);

    med = rez_issue_cell(&field, &home, cell, 8);
    med.gen++;
    CHECK(rez_deref_cell(med) == nullptr);
    med = rez_issue_cell(&field, &home, cell, 8);
    med.home_gen++;
    CHECK(rez_deref_cell(med) == nullptr);
    med = rez_issue_cell(&field, &home, cell, 8);

    CHECK(!rez_cell_bounds(med, UINT64_MAX, 1));
    CHECK(!rez_cell_bounds(med, 0, UINT64_MAX));
    CHECK(rez_arena_alloc_z(&misaligned, 1) == nullptr);
    CHECK(!rez_frame_reset(&invalid, nullptr, misaligned_storage + 1, 64));

    rez_decay(&home);
    CHECK(field.alive);
    CHECK(rez_deref_cell(med) == nullptr);
    CHECK(rez_frame_reset(&home, nullptr, home_arena, 64));
    med = rez_issue_cell(&field, &home, cell, 8);
    rez_decay(&field);
    CHECK(home.alive);
    CHECK(rez_deref_cell(med) == nullptr);
    return 0;
}
