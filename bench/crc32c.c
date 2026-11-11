#include <stddef.h>
#include <stdint.h>

#define INPUT_BYTES 4096ULL

static uint8_t input[INPUT_BYTES];

uint32_t crc32c_software(const uint8_t *data, uint64_t size) {
    uint32_t crc = UINT32_MAX;
    for (uint64_t i = 0; i < size; i++) {
        crc ^= data[i];
        for (unsigned int bit = 0; bit < 8; bit++) {
            uint32_t low = crc & 1U;
            crc >>= 1;
            if (low != 0) crc ^= UINT32_C(0x82f63b78);
        }
    }
    return crc ^ UINT32_MAX;
}

void workload_prepare(void) {
    for (size_t i = 0; i < INPUT_BYTES; i++) {
        input[i] = (uint8_t)((i * 37 + i / 7) & 255);
    }
}

uint64_t workload_step(void) {
    return crc32c_software(input, INPUT_BYTES);
}

uint32_t workload_backend(void) {
    return 0;
}
