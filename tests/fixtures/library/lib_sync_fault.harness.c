#include <stdint.h>
#include <stdio.h>
#include "rez3ext.h"

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

RzaResult rza_boot(void);
RezCellMed rza_med_out_m(void);
void *rza_deref_cell(RezCellMed mediator);

int main(void) {
    RzaResult result = rza_boot();
    CHECK(result.code == RZA_FAULT_ARITHMETIC_OVERFLOW && result.line == 5);
    CHECK(rza_deref_cell(rza_med_out_m()) == NULL);
    printf("fault %u %u\n", result.code, result.line);
    return 0;
}
