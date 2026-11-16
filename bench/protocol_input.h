#ifndef RZA_BENCH_PROTOCOL_INPUT_H
#define RZA_BENCH_PROTOCOL_INPUT_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define PROTOCOL_INPUT_BYTES 4096U
#define PROTOCOL_FRAME_MAX 16U

#ifndef PROTOCOL_VARIANT
#define PROTOCOL_VARIANT 0
#endif

static uint32_t protocol_crc32c_bytes(const uint8_t *data, size_t size) {
    uint32_t crc = UINT32_MAX;
    for (size_t index = 0; index < size; index++) {
        crc ^= data[index];
        for (unsigned int bit = 0; bit < 8; bit++) {
            uint32_t low = crc & 1U;
            crc >>= 1;
            if (low != 0) crc ^= UINT32_C(0x82f63b78);
        }
    }
    return ~crc;
}

static void protocol_put32le(uint8_t *output, uint32_t value) {
    for (unsigned int index = 0; index < 4; index++) {
        output[index] = (uint8_t)(value >> (index * 8));
    }
}

static size_t protocol_build_input(uint8_t *output, int variant) {
    size_t used = 0;
    uint32_t frame = 0;
    while (used < PROTOCOL_INPUT_BYTES) {
        uint8_t data[PROTOCOL_FRAME_MAX] = {0};
        size_t length = variant == 1 ? 8U : variant == 2 ? 1U : 1U + frame % 8U;
        size_t frame_size = length + 8U;
        data[0] = 0xa5;
        data[1] = (uint8_t)length;
        data[2] = (uint8_t)frame;
        for (size_t index = 0; index < length; index++) {
            data[4 + index] = (uint8_t)(frame * 17U + index * 31U);
        }
        uint32_t crc = protocol_crc32c_bytes(data + 4, 8);
        if ((variant == 0 || variant == 3) && frame % 11U == 10U) crc ^= 1U;
        if ((variant == 0 || variant == 3) && frame % 13U == 12U) data[2]++;
        protocol_put32le(data + 4 + length, crc);
        if ((variant == 0 || variant == 3) && frame % 17U == 16U) data[1] = 255;
        if (variant == 3 && frame == 0) data[1] = 255;
        size_t remaining = PROTOCOL_INPUT_BYTES - used;
        size_t copy = frame_size < remaining ? frame_size : remaining;
        memcpy(output + used, data, copy);
        used += copy;
        frame++;
    }
    return variant == 2 ? PROTOCOL_INPUT_BYTES - 2 : PROTOCOL_INPUT_BYTES;
}

#endif
