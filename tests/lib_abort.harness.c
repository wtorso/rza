/* lib_abort_harness.c — прогон runtime-abort каскада.
 * Ожидаемый вывод: "1\n2\n2\n" (второй worker: блок каскада пропущен). */
#include <stdint.h>
#include <stdio.h>
#include "rez3ext.h"

extern RzaResult rza_boot(void);
extern RzaResult rza_setup(void);
extern RzaResult rza_worker(void);
extern RzaResult rza_killer(void);
extern RezCavity *rza_frame_tmp(void);
extern void *rza_arena_alloc(RezCavity *cavity, uint64_t size);

int main(void) {
    if (rza_boot().code != RZA_OK) return 11;
    if (rza_setup().code != RZA_OK) return 12;
    if (rza_worker().code != RZA_OK) return 13;
    if (rza_killer().code != RZA_OK) return 14;
    if (rza_worker().code != RZA_OK) return 15;
    if (rza_arena_alloc(rza_frame_tmp(), 0) != nullptr) return 10;
    return 0;
}
