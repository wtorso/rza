/* lib_abort_harness.c — прогон runtime-abort каскада.
 * Ожидаемый вывод: "1\n2\n2\n" (второй worker: блок каскада пропущен). */
#include <stdio.h>

extern void rza_boot(void);
extern void rza_setup(void);
extern void rza_worker(void);
extern void rza_killer(void);

int main(void) {
    rza_boot();
    rza_setup();
    rza_worker();   /* медиатор жив: печатает 1, потом 2 */
    rza_killer();   /* decay tmp — медиатор мёртв */
    rza_worker();   /* abort: блок пропущен, печатает только 2 */
    return 0;
}
