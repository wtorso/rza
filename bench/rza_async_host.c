#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "rez3ext.h"

#if defined(ASYNC_SINGLE)
#define ASYNC_BOOT_COUNT 1024ULL
#elif defined(ASYNC_QUEUE)
#define ASYNC_BOOT_COUNT 128ULL
#else
#error "select ASYNC_SINGLE or ASYNC_QUEUE"
#endif

#if defined(__clang__)
#define ASYNC_NO_UNROLL _Pragma("clang loop unroll(disable)")
#elif defined(__GNUC__)
#define ASYNC_NO_UNROLL _Pragma("GCC unroll 1")
#else
#define ASYNC_NO_UNROLL
#endif

uint32_t rza_rez3ext_abi(void);
void *rza_deref_cell(RezCellMed mediator);
void rza_boot(void);
void rza_work(void);
RezCellMed rza_med_state_m(void);
RezCellMed rza_med_completed_m(void);

static uint64_t read_cell(RezCellMed mediator) {
    uint64_t *cell = rza_deref_cell(mediator);
    if (cell == NULL) exit(1);
    uint64_t value;
    memcpy(&value, cell, sizeof(value));
    return value;
}

void workload_prepare(void) {
    if (rza_rez3ext_abi() != REZ3EXT_ABI) exit(2);
    rza_boot();
}

uint64_t workload_step(void) {
    uint64_t digest = 0;
    ASYNC_NO_UNROLL
    for (uint64_t iteration = 0; iteration < ASYNC_BOOT_COUNT; iteration++) {
        rza_boot();
        rza_work();
        digest += read_cell(rza_med_state_m());
        digest += read_cell(rza_med_completed_m());
    }
    return digest;
}

uint32_t workload_backend(void) {
    return 0;
}
