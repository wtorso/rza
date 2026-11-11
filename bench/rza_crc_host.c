#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "refs/rez3ext.h"

uint32_t rza_rez3ext_abi(void);
void *rza_deref_cell(RezCellMed mediator);
void rza_boot(void);
void rza_checksum(void);
RezCellMed rza_med_input_m(void);
RezCellMed rza_med_crc_m(void);

void workload_prepare(void) {
    if (rza_rez3ext_abi() != REZ3EXT_ABI) exit(2);
    rza_boot();
    uint8_t *data = rza_deref_cell(rza_med_input_m());
    if (data == NULL) exit(1);
    for (size_t i = 0; i < 4096; i++) {
        data[i] = (uint8_t)((i * 37 + i / 7) & 255);
    }
}

uint64_t workload_step(void) {
    rza_checksum();
    uint64_t *result = rza_deref_cell(rza_med_crc_m());
    if (result == NULL) exit(1);
    uint64_t value;
    memcpy(&value, result, sizeof(value));
    return value;
}

uint32_t workload_backend(void) {
    return 0;
}
