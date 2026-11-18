#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#define _POSIX_C_SOURCE 200809L
#include <time.h>
#endif

#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define SAMPLE_MAX 101ULL
#define BATCH_MAX 1000000ULL
#define NS_PER_SECOND 1000000000ULL

void workload_prepare(void);
uint64_t workload_step(void);
uint32_t workload_backend(void);

static volatile uint64_t observed_result;
static uint64_t timer_ticks_hz;

static const char *backend_label(uint32_t backend) {
    if (backend == 0) return "software";
    if (backend == 1) return "hardware_sse42";
    return "unknown";
}

static bool read_count(const char *text, uint64_t maximum, uint64_t *result) {
    if (text == NULL || text[0] == '\0' || text[0] == '-') return false;
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0') return false;
    if (value == 0 || value > maximum) return false;
    *result = (uint64_t)value;
    return true;
}

static int compare_u64(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left;
    uint64_t b = *(const uint64_t *)right;
    return (a > b) - (a < b);
}

static bool timer_init(void) {
#if defined(_WIN32)
    LARGE_INTEGER frequency;
    if (QueryPerformanceFrequency(&frequency) == 0 || frequency.QuadPart <= 0) {
        return false;
    }
    timer_ticks_hz = (uint64_t)frequency.QuadPart;
#else
    timer_ticks_hz = NS_PER_SECOND;
#endif
    return true;
}

static bool timer_now(uint64_t *result) {
#if defined(_WIN32)
    LARGE_INTEGER counter;
    if (QueryPerformanceCounter(&counter) == 0 || counter.QuadPart < 0) return false;
    *result = (uint64_t)counter.QuadPart;
#else
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return false;
    *result = (uint64_t)now.tv_sec * NS_PER_SECOND + (uint64_t)now.tv_nsec;
#endif
    return true;
}

static uint64_t elapsed_ns(uint64_t start, uint64_t end) {
    assert(timer_ticks_hz > 0);
    uint64_t ticks = end - start;
    uint64_t seconds = ticks / timer_ticks_hz;
    uint64_t remainder = ticks % timer_ticks_hz;
    return seconds * NS_PER_SECOND + remainder * NS_PER_SECOND / timer_ticks_hz;
}

int run_timer(int argc, char **argv) {
    uint64_t sample_count = 11;
    uint64_t batch_count = 256;
    if (argc == 3) {
        if (!read_count(argv[1], SAMPLE_MAX, &sample_count) ||
                !read_count(argv[2], BATCH_MAX, &batch_count)) {
            fprintf(stderr, "usage: %s [samples 1..101 batch 1..1000000]\n", argv[0]);
            return 2;
        }
    } else if (argc != 1) {
        fprintf(stderr, "usage: %s [samples 1..101 batch 1..1000000]\n", argv[0]);
        return 2;
    }
    if (!timer_init()) return 3;
    uint64_t samples_ns[SAMPLE_MAX];
    workload_prepare();
    uint64_t result = workload_step();
    uint64_t expected = result;
    for (uint64_t warmup = 1; warmup < batch_count * 2; warmup++) {
        result = workload_step();
        if (result != expected) {
            fprintf(stderr, "workload result changed between warmup steps\n");
            return 4;
        }
    }
    for (uint64_t sample = 0; sample < sample_count; sample++) {
        uint64_t start;
        uint64_t end;
        if (!timer_now(&start)) return 3;
        for (uint64_t iteration = 0; iteration < batch_count; iteration++) {
            result = workload_step();
            if (result != expected) {
                fprintf(stderr, "workload result changed between steps\n");
                return 4;
            }
            observed_result = result;
        }
        if (!timer_now(&end)) return 3;
        samples_ns[sample] = elapsed_ns(start, end);
    }
    qsort(samples_ns, (size_t)sample_count, sizeof(samples_ns[0]), compare_u64);
    printf("result=%" PRIu64 " backend=%s samples=%" PRIu64 " batch=%" PRIu64 "\n",
            result, backend_label(workload_backend()), sample_count, batch_count);
    printf("median_ns=%" PRIu64 " min_ns=%" PRIu64 " max_ns=%" PRIu64 "\n",
            samples_ns[sample_count / 2], samples_ns[0], samples_ns[sample_count - 1]);
    fputs("samples_ns=", stdout);
    for (uint64_t i = 0; i < sample_count; i++) {
        printf("%s%" PRIu64, i == 0 ? "" : ",", samples_ns[i]);
    }
    putchar('\n');
    return 0;
}
