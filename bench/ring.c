#include <stdint.h>

typedef struct {
    uint64_t read_pos;
    uint64_t count;
    uint64_t input;
    uint64_t output;
    uint64_t full;
    uint64_t empty;
    uint64_t slots[4];
    uint64_t result;
} Ring;

static Ring ring;

static void push(void) {
    if (ring.count == 4) {
        ring.full++;
        return;
    }
    uint64_t write_pos = (ring.read_pos + ring.count) & 3U;
    ring.slots[write_pos] = ring.input;
    ring.count++;
}

static void pop(void) {
    if (ring.count == 0) {
        ring.empty++;
        return;
    }
    ring.output = ring.slots[ring.read_pos];
    ring.read_pos = (ring.read_pos + 1) & 3U;
    ring.count--;
    ring.result += ring.output;
}

uint64_t ring_step(void) {
    ring.read_pos = 0;
    ring.count = 0;
    ring.full = 0;
    ring.empty = 0;
    ring.result = 0;
    pop();
    for (uint64_t request = 0; request < 1024; request++) {
        if ((request & 7U) < 5) {
            ring.input = request + 1;
            push();
        } else {
            pop();
        }
    }
    ring.result += ring.full + ring.empty;
    return ring.result;
}

void workload_prepare(void) {}

uint64_t workload_step(void) {
    return ring_step();
}

uint32_t workload_backend(void) {
    return 0;
}
