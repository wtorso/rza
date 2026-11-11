#include <stdint.h>
#include <stdio.h>

int main(void) {
    int64_t a = 0;
    int64_t b = 1;
    for (int64_t i = 1000000; i != 0; i--) {
        int64_t next = a + b;
        a = b;
        b = next;
    }
    printf("%lld\n", (long long)a);
    return 0;
}
