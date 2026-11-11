#include <stdint.h>
#include "rez3ext.h"

uint32_t rza_rez3ext_abi(void);
void rza_boot(void);
uint64_t rza_await(void);

int main(void) {
    if (rza_rez3ext_abi() != 4) return 1;
    rza_boot();
    if (rza_await() != 0) return 2;
    return 0;
}
