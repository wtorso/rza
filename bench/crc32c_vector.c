#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef CRC32C_TABLE
uint32_t crc32c_table(const uint8_t *data, uint64_t size);
void workload_prepare(void);
#define CRC32C_FUNCTION crc32c_table
#else
uint32_t crc32c_software(const uint8_t *data, uint64_t size);
#define CRC32C_FUNCTION crc32c_software
#endif

int main(void) {
    static const uint8_t vector[] = "123456789";
#ifdef CRC32C_TABLE
    workload_prepare();
#endif
    uint32_t actual = CRC32C_FUNCTION(vector, strlen((const char *)vector));
    printf("%08" PRIx32 "\n", actual);
    return actual == UINT32_C(0xe3069283) ? 0 : 1;
}
