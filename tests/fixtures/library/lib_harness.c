/* lib_harness.c — харнес для lib_hello.rza (--emit-lib): зовёт экспортные
 * точки входа сгенерированной библиотеки. Ожидаемый вывод: "42\nharness done".
 */
#include <stdio.h>
#include "rez3ext.h"

extern RzaResult rza_boot(void);
extern RzaResult rza_greet(void);

int main(void) {
    if (rza_boot().code != RZA_OK) return 10;
    if (rza_greet().code != RZA_OK) return 11;
    printf("harness done\n");
    return 0;
}
