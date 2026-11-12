#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "rez3ext.h"

extern void rza_boot(void);
extern void rza_setup(void);
extern RezCellMed rza_med_entries_m(void);
extern void *rza_deref_cell(RezCellMed mediator);
extern uint32_t rza_rez3ext_abi(void);

int main(void) {
    if (rza_rez3ext_abi() != 4) return 10;
    rza_boot();
    rza_setup();
    RezCellMed mediator = rza_med_entries_m();
    if (mediator.size != 32) return 11;
    void *cell = rza_deref_cell(mediator);
    if (cell == NULL) return 12;
    int64_t key = 0;
    int64_t value = 0;
    memcpy(&key, cell, 8);
    memcpy(&value, (char *)cell + 8, 8);
    if (key != 11) return 13;
    if (value != 7) return 14;
    printf("lib typed ok\n");
    return 0;
}
