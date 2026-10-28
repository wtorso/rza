/* lib_abort_harness.c — прогон runtime-abort каскада.
 * Ожидаемый вывод: "1\n2\n2\n" (второй worker: блок каскада пропущен). */
#include <stdint.h>
#include <stdio.h>

typedef struct RezCavity RezCavity;
extern void rza_boot(void);
extern void rza_setup(void);
extern void rza_worker(void);
extern void rza_killer(void);
extern RezCavity *rza_frame_tmp(void);
extern void *rza_arena_alloc(RezCavity *cavity, uint64_t size);

int main(void) {
    rza_boot();
    rza_setup();
    rza_worker();   /* медиатор жив: печатает 1, потом 2 */
    rza_killer();   /* decay tmp — медиатор мёртв */
    rza_worker();   /* abort: блок пропущен, печатает только 2 */
    if (rza_arena_alloc(rza_frame_tmp(), 0) != nullptr) return 10;
    return 0;
}
