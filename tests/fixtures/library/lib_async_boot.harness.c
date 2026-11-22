#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
RzaResult rza_boot(void);
RzaAwaitResult rza_await(void);
RezCellMed rza_med_x_m(void);
RezCellMed rza_med_boot_out_m(void);
void *rza_deref_cell(RezCellMed mediator);

int main(void) {
    if (rza_rez3ext_abi() != 5) return 10;
    if (rza_boot().code != RZA_OK) return 14;
    RzaAwaitResult awaited = rza_await();
    if (awaited.result.code != RZA_OK || awaited.completed != 0) return 11;
    int64_t value = -1;
    memcpy(&value, rza_deref_cell(rza_med_x_m()), sizeof(value));
    if (value != 1) return 12;
    if (rza_deref_cell(rza_med_boot_out_m()) == NULL) return 13;
    printf("%lld\n", (long long)value);
    return 0;
}
