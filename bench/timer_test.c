#include <stdint.h>
#include <stdio.h>

int run_timer(int argc, char **argv);

static unsigned int prepare_calls;
static unsigned int step_calls;
static unsigned int unstable_after;

void workload_prepare(void) {
    prepare_calls++;
}

uint64_t workload_step(void) {
    step_calls++;
    return unstable_after != 0 && step_calls > unstable_after ? 43 : 42;
}

int main(void) {
    char *args[] = {"timer_test", "3", "5"};
    if (run_timer(3, args) != 0) return 1;
    if (prepare_calls != 1 || step_calls != 25) {
        fprintf(stderr, "counts: prepare=%u step=%u, want 1 and 25\n",
                prepare_calls, step_calls);
        return 2;
    }
    unstable_after = step_calls + 10;
    if (run_timer(3, args) != 4) return 3;
    if (prepare_calls != 2 || step_calls != 36) return 4;
    unstable_after = step_calls + 1;
    if (run_timer(3, args) != 4) return 5;
    if (prepare_calls != 3 || step_calls != 38) return 6;
    unstable_after = 0;
    char *invalid[] = {"timer_test", "0", "5"};
    if (run_timer(3, invalid) != 2) return 7;
    if (prepare_calls != 3 || step_calls != 38) return 8;
    puts("PASS timer warmup/batch/argument checks");
    return 0;
}

uint32_t workload_backend(void) {
    return 0;
}
