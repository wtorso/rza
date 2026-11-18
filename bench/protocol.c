#include <stdbool.h>
#include <stdint.h>

#include "protocol_input.h"

typedef struct {
    uint64_t accepted;
    uint64_t invalid;
    uint64_t dropped;
    uint64_t truncated;
    uint64_t quota_faults;
    uint64_t total_payload;
    uint64_t expected_sequence;
    uint64_t digest;
    uint64_t ring_count;
    uint64_t ring_read;
    uint8_t ring[4][8];
} ProtocolState;

static uint32_t protocol_crc_word(const uint8_t word[8]) {
    return protocol_crc32c_bytes(word, 8);
}

static void protocol_pop(ProtocolState *state) {
    state->digest += protocol_crc_word(state->ring[state->ring_read]);
    state->ring_read = (state->ring_read + 1) & 3;
    state->ring_count--;
}

static uint64_t protocol_finish(ProtocolState *state) {
    while (state->ring_count > 0) protocol_pop(state);
    return state->digest + state->accepted * UINT64_C(1000) +
        state->invalid * UINT64_C(1000000) + state->dropped * UINT64_C(1000000000) +
        state->truncated * UINT64_C(1000000000000) +
        state->quota_faults * UINT64_C(1000000000000000);
}

uint64_t protocol_step(const uint8_t *input, uint64_t input_size) {
    ProtocolState state = {0};
    uint64_t offset = 0;
    while (offset < input_size) {
        if (input_size - offset < 4) {
            state.truncated++;
            break;
        }
        if (input[offset] != 0xa5) {
            state.invalid++;
            offset++;
            continue;
        }
        uint64_t length = input[offset + 1];
        if (length > 8) {
            state.invalid++;
            offset++;
            continue;
        }
        uint64_t next = offset + length + 8;
        if (next > input_size) {
            state.truncated++;
            break;
        }
        uint64_t current = offset;
        offset = next;
        uint64_t sequence = input[current + 2];
        bool sequence_ok = sequence == state.expected_sequence;
        state.expected_sequence = (sequence + 1) & 255;
        if (!sequence_ok) state.invalid++;
        if (input[current + 3] != 0) {
            state.invalid++;
            continue;
        }
        state.total_payload += length;
        if (state.total_payload > 1024) {
            state.quota_faults++;
            break;
        }
        uint8_t scratch[8] = {0};
        memcpy(scratch, input + current + 4, length);
        uint32_t expected_crc = 0;
        for (unsigned int index = 0; index < 4; index++) {
            expected_crc |= (uint32_t)input[current + 4 + length + index] << (index * 8);
        }
        if (protocol_crc_word(scratch) != expected_crc) {
            state.invalid++;
            continue;
        }
        state.accepted++;
        if (state.ring_count < 4) {
            uint64_t write = (state.ring_read + state.ring_count) & 3;
            memcpy(state.ring[write], scratch, 8);
            state.ring_count++;
        } else {
            state.dropped++;
        }
        if (state.accepted % 3 == 0 && state.ring_count > 0) protocol_pop(&state);
    }
    return protocol_finish(&state);
}

static uint8_t input[PROTOCOL_INPUT_BYTES];
static uint64_t input_size;

void workload_prepare(void) {
    input_size = protocol_build_input(input, PROTOCOL_VARIANT);
}

uint64_t workload_step(void) {
    return protocol_step(input, input_size);
}

uint32_t workload_backend(void) {
    return 0;
}
