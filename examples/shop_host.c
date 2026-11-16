#include <stdint.h>
#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
RzaResult rza_boot(void);
RzaAwaitResult rza_await(void);
RezCellMed rza_med_cart_m(void);
void *rza_deref_cell(RezCellMed mediator);

int main(void) {
    if (rza_rez3ext_abi() != 5) return 1;
    if (rza_boot().code != RZA_OK) return 4;
    if (rza_await().completed != 0) return 2;
    if (rza_deref_cell(rza_med_cart_m()) != nullptr) return 3;
    return 0;
}
