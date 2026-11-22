#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "rez3ext.h"

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

static uint32_t callback_reentry;
static uint32_t callback_count;
static uint32_t callback_fault;
static char callback_operation[64];

RzaResult rza_succeed(void);

static void on_diagnostic(RzaDiagnostic diagnostic, void *context) {
    if (context != NULL) return;
    callback_count++;
    callback_fault = diagnostic.fault;
    callback_reentry = rza_succeed().code == RZA_FAULT_ENTRY_STATE
        ? RZA_FAULT_ENTRY_STATE : RZA_OK;
    snprintf(callback_operation, sizeof(callback_operation), "%s",
        diagnostic.operation == NULL ? "" : diagnostic.operation);
}

uint32_t rza_rez3ext_abi(void);
RzaResult rza_boot(void);
RzaResult rza_fail(void);
RezCavity *rza_frame_fail(void);
RezCellMed rza_med_state_m(void);
void *rza_deref_cell(RezCellMed mediator);
void rza_set_diagnostic_handler(RzaDiagnosticHandler handler, void *context);

static int64_t read_word(RezCellMed mediator, uint64_t offset) {
    int64_t value = INT64_MIN;
    void *cell = rza_deref_cell(mediator);
    if (cell != NULL) memcpy(&value, (char *)cell + offset, sizeof(value));
    return value;
}

int main(void) {
    static_assert(REZ3EXT_ABI == 5);
    CHECK(rza_rez3ext_abi() == 5);
    RzaResult boot = rza_boot();
    CHECK(boot.code == RZA_OK && boot.line == 0);
    printf("boot %u\n", boot.code);
    RzaResult repeat = rza_boot();
    CHECK(repeat.code == RZA_FAULT_ENTRY_STATE);
    printf("repeat %u %lld\n", repeat.code, (long long)read_word(rza_med_state_m(), 0));
    RzaResult first = rza_succeed();
    CHECK(first.code == RZA_OK);
    printf("first %u %lld\n", first.code, (long long)read_word(rza_med_state_m(), 8));

    rza_set_diagnostic_handler(on_diagnostic, NULL);
    RzaResult fault = rza_fail();
    CHECK(fault.code == RZA_FAULT_ARITHMETIC_OVERFLOW && fault.line == 11);
    CHECK(!rza_frame_fail()->alive);
    CHECK(read_word(rza_med_state_m(), 0) == 5);
    printf("fault %u %u %lld %d\n", fault.code, fault.line,
        (long long)read_word(rza_med_state_m(), 0), rza_frame_fail()->alive);
    RzaResult retry = rza_succeed();
    CHECK(retry.code == RZA_OK);
    printf("retry %u %lld\n", retry.code, (long long)read_word(rza_med_state_m(), 8));
    CHECK(callback_count == 1 && callback_fault == RZA_FAULT_ARITHMETIC_OVERFLOW);
    CHECK(strcmp(callback_operation, "arithmetic overflow") == 0);
    printf("diag %u %s\n", callback_fault, callback_operation);
    CHECK(callback_reentry == RZA_FAULT_ENTRY_STATE);
    printf("reentry %u %u\n", callback_reentry, fault.code);
    return 0;
}
