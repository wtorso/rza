#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
void rza_boot(void);
uint64_t rza_await(void);
RezCellMed rza_med_x_m(void);
RezCellMed rza_med_boot_out_m(void);
void *rza_deref_cell(RezCellMed mediator);

int main(void) {
    if (rza_rez3ext_abi() != 4) return 10;
    rza_boot();
    if (rza_await() != 0) return 11;
    int64_t value = -1;
    memcpy(&value, rza_deref_cell(rza_med_x_m()), sizeof(value));
    if (value != 1) return 12;
    if (rza_deref_cell(rza_med_boot_out_m()) == nullptr) return 13;
    printf("%lld\n", (long long)value);
    return 0;
}
