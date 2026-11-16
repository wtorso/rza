#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "protocol_input.h"
#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
void *rza_deref_cell(RezCellMed mediator);
RzaResult rza_boot(void);
RzaResult rza_process(void);
RezCellMed rza_med_input_m(void);
RezCellMed rza_med_control_m(void);
RezCellMed rza_med_result_m(void);

void workload_prepare(void) {
    if (rza_rez3ext_abi() != REZ3EXT_ABI) exit(2);
    if (rza_boot().code != RZA_OK) exit(1);
    uint8_t *input = rza_deref_cell(rza_med_input_m());
    uint64_t *control = rza_deref_cell(rza_med_control_m());
    if (input == NULL || control == NULL) exit(1);
    *control = protocol_build_input(input, PROTOCOL_VARIANT);
}

uint64_t workload_step(void) {
    if (rza_process().code != RZA_OK) exit(1);
    uint64_t *result = rza_deref_cell(rza_med_result_m());
    if (result == NULL) exit(1);
    uint64_t value;
    memcpy(&value, result, sizeof(value));
    return value;
}

uint32_t workload_backend(void) {
    return rez_crc32c_hardware() ? 1U : 0U;
}
