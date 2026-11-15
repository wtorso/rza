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
void rza_boot(void);
void rza_reset(void);
void rza_work(void);
void rza_workload(void);
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
    rza_boot();
}

#if defined(CALLS_INTERNAL)
uint64_t workload_step(void) {
    rza_workload();
    return read_state();
}
#elif defined(CALLS_ABI_DIRECT)
uint64_t workload_step(void) {
    rza_reset();
    CALLS_NO_UNROLL
    for (uint64_t iteration = 0; iteration < CALL_COUNT; iteration++) rza_work();
    return read_state();
}
#elif defined(CALLS_ABI_INDIRECT)
static void (*volatile work_target)(void) = rza_work;

uint64_t workload_step(void) {
    rza_reset();
    CALLS_NO_UNROLL
    for (uint64_t iteration = 0; iteration < CALL_COUNT; iteration++) work_target();
    return read_state();
}
#else
#error "select CALLS_INTERNAL, CALLS_ABI_DIRECT, or CALLS_ABI_INDIRECT"
#endif

uint32_t workload_backend(void) {
    return 0;
}
