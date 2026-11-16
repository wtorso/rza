#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
RzaResult rza_boot(void);
RzaResult rza_bump(void);
RzaAwaitResult rza_await(void);
void *rza_deref_cell(RezCellMed mediator);
RezCellMed rza_med_x_m(void);
RezCellMed rza_med_out_m(void);

int main(void) {
    if (rza_rez3ext_abi() != 5) return 10;
    if (rza_boot().code != RZA_OK) return 17;
    RezCellMed pending = rza_med_out_m();
    if (pending.cell != nullptr) return 11;
    if (rza_bump().code != RZA_OK) return 18;
    if (rza_deref_cell(pending) != nullptr) return 16;
    RezCellMed completed = rza_med_out_m();
    if (completed.cell == nullptr) return 12;
    if (rza_await().completed != 0) return 13;
    int64_t value = -1;
    memcpy(&value, rza_deref_cell(rza_med_x_m()), sizeof(value));
    if (value != 1) return 14;
    int64_t out_value = -1;
    memcpy(&out_value, rza_deref_cell(completed), sizeof(out_value));
    if (out_value != 0) return 15;
    printf("%lld\n", (long long)value);
    if (rza_bump().code != RZA_OK) return 19;
    if (rza_deref_cell(completed) != nullptr) return 20;
    RezCellMed republished = rza_med_out_m();
    if (republished.cell == nullptr) return 21;
    memcpy(&out_value, rza_deref_cell(republished), sizeof(out_value));
    if (out_value != 0) return 22;
    return 0;
}
