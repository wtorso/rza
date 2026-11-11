#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
void rza_boot(void);
void rza_bump(void);
uint64_t rza_await(void);
void *rza_deref_cell(RezCellMed mediator);
RezCellMed rza_med_x_m(void);
RezCellMed rza_med_out_m(void);

int main(void) {
    if (rza_rez3ext_abi() != 4) return 10;
    rza_boot();
    RezCellMed pending = rza_med_out_m();
    if (pending.cell != nullptr) return 11;
    rza_bump();
    RezCellMed completed = rza_med_out_m();
    if (completed.cell == nullptr) return 12;
    if (rza_await() != 0) return 13;
    int64_t value = -1;
    memcpy(&value, rza_deref_cell(rza_med_x_m()), sizeof(value));
    if (value != 1) return 14;
    int64_t out_value = -1;
    memcpy(&out_value, rza_deref_cell(completed), sizeof(out_value));
    if (out_value != 0) return 15;
    printf("%lld\n", (long long)value);
    return 0;
}
