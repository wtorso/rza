#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
void *rza_deref_cell(RezCellMed mediator);
RzaResult rza_boot(void);
RzaResult rza_parse(void);
RezCellMed rza_med_input_m(void);
RezCellMed rza_med_result_m(void);

void workload_prepare(void) {
    static const uint8_t pattern[] = "abc=12;#x=4;z=9;";
    if (rza_rez3ext_abi() != REZ3EXT_ABI) exit(2);
    if (rza_boot().code != RZA_OK) exit(1);
    uint8_t *data = rza_deref_cell(rza_med_input_m());
    if (data == NULL) exit(1);
    for (size_t i = 0; i < 4096; i++) data[i] = pattern[i % 16];
}

uint64_t workload_step(void) {
    if (rza_parse().code != RZA_OK) exit(1);
    uint64_t *result = rza_deref_cell(rza_med_result_m());
    if (result == NULL) exit(1);
    uint64_t value;
    memcpy(&value, result, sizeof(value));
    return value;
}

uint32_t workload_backend(void) {
    return 0;
}
