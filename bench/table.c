#include <stdint.h>
#include <string.h>

#define TABLE_SLOTS 512ULL
#define REQUEST_COUNT 1024ULL

typedef struct {
    uint64_t key;
    uint64_t value;
} Entry;

static Entry slots[TABLE_SLOTS];

uint64_t table_step(void) {
    memset(slots, 0, sizeof(slots));
    for (uint64_t request = 0; request < REQUEST_COUNT; request++) {
        uint64_t key = ((request * 37 + 11) & 255) + 1;
        uint64_t slot = (key * UINT64_C(2654435761)) & (TABLE_SLOTS - 1);
        uint64_t probes;
        for (probes = 0; probes < TABLE_SLOTS; probes++) {
            if (slots[slot].key == 0) {
                slots[slot] = (Entry){key, request & 7};
                break;
            }
            if (slots[slot].key == key) {
                slots[slot].value += request & 7;
                break;
            }
            slot = (slot + 1) & (TABLE_SLOTS - 1);
        }
        if (probes == TABLE_SLOTS) return 0;
    }
    uint64_t digest = 0;
    for (uint64_t i = 0; i < TABLE_SLOTS; i++) {
        if (slots[i].key != 0) digest += slots[i].key * slots[i].value;
    }
    return digest;
}

void workload_prepare(void) {}

uint64_t workload_step(void) {
    return table_step();
}

uint32_t workload_backend(void) {
    return 0;
}
