#include <stddef.h>
#include <stdint.h>

#define INPUT_BYTES 4096U

static uint8_t input[INPUT_BYTES];

static int is_alpha(uint8_t byte) {
    uint8_t upper = byte & 223U;
    return upper >= 'A' && upper <= 'Z';
}

uint64_t parse(const uint8_t *data, size_t size) {
    uint64_t state = 0;
    uint64_t value = 0;
    uint64_t records = 0;
    uint64_t invalid = 0;
    uint64_t sum = 0;
    for (size_t i = 0; i < size; i++) {
        uint8_t byte = data[i];
        int alpha = is_alpha(byte);
        int digit = byte >= '0' && byte <= '9';
        if (state == 0) {
            if (alpha) state = 1;
            else invalid++;
        } else if (state == 1) {
            if (alpha || digit) continue;
            if (byte == '=') {
                state = 2;
                value = 0;
            } else {
                invalid++;
                state = 0;
                value = 0;
            }
        } else {
            if (digit) {
                value = value * 10 + (byte - '0');
            } else if (byte == ';') {
                records++;
                sum += value;
                value = 0;
                state = 0;
            } else {
                invalid++;
                state = 0;
                value = 0;
            }
        }
    }
    return records * 1000000 + invalid * 1000 + sum;
}

void workload_prepare(void) {
    static const uint8_t pattern[] = "abc=12;#x=4;z=9;";
    for (size_t i = 0; i < INPUT_BYTES; i++) input[i] = pattern[i % 16];
}

uint64_t workload_step(void) {
    return parse(input, INPUT_BYTES);
}

uint32_t workload_backend(void) {
    return 0;
}
