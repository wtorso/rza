#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
void *rza_deref_cell(RezCellMed mediator);
RzaResult rza_boot(void);
RzaResult rza_ring(void);
RezCellMed rza_med_result_m(void);

void workload_prepare(void) {
    if (rza_rez3ext_abi() != REZ3EXT_ABI) exit(2);
    if (rza_boot().code != RZA_OK) exit(1);
}

uint64_t workload_step(void) {
    if (rza_ring().code != RZA_OK) exit(1);
    uint64_t *result = rza_deref_cell(rza_med_result_m());
    if (result == NULL) exit(1);
    uint64_t value;
    memcpy(&value, result, sizeof(value));
    return value;
}

uint32_t workload_backend(void) {
    return 0;
}
