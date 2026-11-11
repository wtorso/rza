#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

uint32_t crc32c_software(const uint8_t *data, uint64_t size);

int main(void) {
    static const uint8_t vector[] = "123456789";
    uint32_t actual = crc32c_software(vector, strlen((const char *)vector));
    printf("%08" PRIx32 "\n", actual);
    return actual == UINT32_C(0xe3069283) ? 0 : 1;
}
