#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

void workload_prepare(void);
uint64_t workload_step(void);

int main(void) {
    workload_prepare();
    uint64_t first = workload_step();
    uint64_t second = workload_step();
    if (first != second) {
        fprintf(stderr, "non-repeatable workload: %" PRIu64 " != %" PRIu64 "\n",
                first, second);
        return 1;
    }
    printf("%" PRIu64 "\n%" PRIu64 "\n", first, second);
    return 0;
}
