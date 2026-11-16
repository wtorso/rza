#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "rez3ext.h"

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

RzaResult rza_boot(void);
RezCellMed rza_med_state_m(void);
void *rza_deref_cell(RezCellMed mediator);

int main(void) {
    RzaResult fault = rza_boot();
    CHECK(fault.code == RZA_FAULT_ARITHMETIC_OVERFLOW && fault.line == 4);
    printf("fault %u %u\n", fault.code, fault.line);
    RzaResult repeat = rza_boot();
    CHECK(repeat.code == RZA_FAULT_ENTRY_STATE);
    void *cell = rza_deref_cell(rza_med_state_m());
    CHECK(cell != nullptr);
    int64_t value = -1;
    memcpy(&value, cell, sizeof(value));
    CHECK(value == 0);
    printf("repeat %u %lld\n", repeat.code, (long long)value);
    return 0;
}
