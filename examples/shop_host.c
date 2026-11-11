#include <stdint.h>
#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
void rza_boot(void);
uint64_t rza_await(void);
RezCellMed rza_med_cart_m(void);
void *rza_deref_cell(RezCellMed mediator);

int main(void) {
    if (rza_rez3ext_abi() != 4) return 1;
    rza_boot();
    if (rza_await() != 0) return 2;
    if (rza_deref_cell(rza_med_cart_m()) != nullptr) return 3;
    return 0;
}
