/* lib_harness.c — харнес для lib_hello.rza (--emit-lib): зовёт экспортные
 * точки входа сгенерированной библиотеки. Ожидаемый вывод: "42\nharness done".
 */
#include <stdio.h>

extern void rza_boot(void);
extern void rza_greet(void);

int main(void) {
    rza_boot();
    rza_greet();
    printf("harness done\n");
    return 0;
}
