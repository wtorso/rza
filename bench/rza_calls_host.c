#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "rez3ext.h"

#define CALL_COUNT 1024ULL

#if defined(__clang__)
#define CALLS_NO_UNROLL _Pragma("clang loop unroll(disable)")
#elif defined(__GNUC__)
#define CALLS_NO_UNROLL _Pragma("GCC unroll 1")
#else
#define CALLS_NO_UNROLL
#endif

uint32_t rza_rez3ext_abi(void);
void *rza_deref_cell(RezCellMed mediator);
RzaResult rza_boot(void);
RzaResult rza_reset(void);
RzaResult rza_work(void);
RzaResult rza_workload(void);
RezCellMed rza_med_state_m(void);

static uint64_t read_state(void) {
    uint64_t *result = rza_deref_cell(rza_med_state_m());
    if (result == NULL) exit(1);
    uint64_t value;
    memcpy(&value, result, sizeof(value));
    return value;
}

void workload_prepare(void) {
    if (rza_rez3ext_abi() != REZ3EXT_ABI) exit(2);
    if (rza_boot().code != RZA_OK) exit(1);
}

#if defined(CALLS_INTERNAL)
uint64_t workload_step(void) {
    if (rza_workload().code != RZA_OK) exit(1);
    return read_state();
}
#elif defined(CALLS_ABI_DIRECT)
uint64_t workload_step(void) {
    if (rza_reset().code != RZA_OK) exit(1);
    CALLS_NO_UNROLL
    for (uint64_t iteration = 0; iteration < CALL_COUNT; iteration++) {
        if (rza_work().code != RZA_OK) exit(1);
    }
    return read_state();
}
#elif defined(CALLS_ABI_INDIRECT)
static RzaResult (*volatile work_target)(void) = rza_work;

uint64_t workload_step(void) {
    if (rza_reset().code != RZA_OK) exit(1);
    CALLS_NO_UNROLL
    for (uint64_t iteration = 0; iteration < CALL_COUNT; iteration++) {
        if (work_target().code != RZA_OK) exit(1);
    }
    return read_state();
}
#else
#error "select CALLS_INTERNAL, CALLS_ABI_DIRECT, or CALLS_ABI_INDIRECT"
#endif

uint32_t workload_backend(void) {
    return 0;
}
