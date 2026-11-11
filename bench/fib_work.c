#include <stdint.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    uint64_t a = 0;
    uint64_t b = 1;
    for (uint64_t i = 1000000; i != 0; i--) {
        uint64_t next = a + b;
        a = b;
        b = next;
    }
    int64_t signed_value;
    memcpy(&signed_value, &a, sizeof(signed_value));
    printf("%lld\n", (long long)signed_value);
    return 0;
}
