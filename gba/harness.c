/* harness.c — GBA bare-metal стенд для сгенерированного .rza-кода.
 * printf/fprintf пишут значения в лог EWRAM, exit оставляет маркер конца.
 * malloc — bump по EWRAM; лог читается через просмотр памяти эмулятора. */
#include <stdint.h>
#include <stdarg.h>
/* bare metal: libc нет — свои типы и memset/memcpy */
typedef __SIZE_TYPE__ size_t;
void *memset(void *d, int c, size_t n) {
    unsigned char *p = (unsigned char *)d;
    while (n--) { *p++ = (unsigned char)c; }
    return d;
}
void *memcpy(void *d, const void *s, size_t n) {
    unsigned char *dst = (unsigned char *)d;
    const unsigned char *src = (const unsigned char *)s;
    while (n--) { *dst++ = *src++; }
    return d;
}

#define EWRAM_BASE 0x02000000u
#define EWRAM_END  0x02040000u

/* [0] = magic после exit; [1..] = значения i64. count не сохраняется. */
volatile int64_t *const rza_log = (volatile int64_t *)EWRAM_BASE;
static uint32_t log_n;
static char *heap = (char *)(EWRAM_BASE + 0x10000);   /* лог — первые 4K */

static void log_i64(int64_t v) {
    if (log_n < 500) { rza_log[1 + log_n++] = v; }
}

int printf(const char *fmt, ...) {
    va_list ap;
    int64_t v;
    va_start(ap, fmt);
    if (fmt[0] == '%' && fmt[1] == 's') {
        const char *s = va_arg(ap, const char *);
        v = s && s[0] == 'A' ? 1 : 0;   /* ALIVE = 1, DEAD = 0 */
    } else {
        v = va_arg(ap, int64_t);        /* %lld */
    }
    va_end(ap);
    log_i64(v);
    return 0;
}

int fprintf(void *stream, const char *fmt, ...) {
    va_list ap;
    int line;
    (void)stream;
    va_start(ap, fmt);
    line = va_arg(ap, int);             /* FAULT/ABORT: первый аргумент = line */
    va_end(ap);
    log_i64(line);
    return 0;
}

void exit(int code) {
    log_i64(0x0DEC0DE000000000LL | (int64_t)(code & 0xff));
    rza_log[0] = 0x1A5A525A31LL;   /* magic: тесты завершены */
    for (;;) { }
}

void *malloc(size_t n) {
    void *p = heap;
    heap += (n + 15) & ~15u;
    if ((uint32_t)heap > EWRAM_END) { exit(2); }
    return p;
}
void free(void *p) { (void)p; }
void *calloc(size_t n, size_t sz) { void *p = malloc(n * sz); memset(p, 0, n * sz); return p; }
