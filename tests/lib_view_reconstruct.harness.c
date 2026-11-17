#include <stdint.h>
#include <stdio.h>
#include "rez3ext.h"

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

RzaResult rza_boot(void);
RzaResult rza_bump(void);
RzaResult rza_update_view(void);
RezCellMed rza_med_out_m(void);
RezCellMed rza_med_tail_m(void);
RezCellMed rza_med_control_m(void);
void *rza_deref_cell(RezCellMed mediator);

int main(void) {
    CHECK(rza_boot().code == RZA_OK);
    CHECK(rza_bump().code == RZA_OK);
    CHECK(rza_update_view().code == RZA_OK);
    RezCellMed initial = rza_med_tail_m();
    CHECK(initial.size == 4 && rza_deref_cell(initial) != NULL);
    int64_t *control = rza_deref_cell(rza_med_control_m());
    CHECK(control != NULL);
    *control = -1;
    RzaResult bad = rza_update_view();
    CHECK(bad.code == RZA_FAULT_VIEW && bad.line == 16);
    RzaResult next = rza_bump();
    CHECK(next.code == RZA_OK);
    RezCellMed restored = rza_med_tail_m();
    CHECK(restored.size == 4 && rza_deref_cell(restored) != NULL);
    CHECK(rza_deref_cell(rza_med_out_m()) != NULL);
    printf("bad %u next %u size %llu\n", bad.code, next.code,
        (unsigned long long)restored.size);
    return 0;
}
