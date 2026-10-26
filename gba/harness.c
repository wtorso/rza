/* harness.c — GBA bare-metal стенд для сгенерированного .rza-кода.
 * Заглушки вместо libc: printf/fprintf пишут i64-аргументы в лог EWRAM,
 * exit — магический маркер конца + стоп; malloc — bump по EWRAM.
 * Читаем лог из sly (Memory viewer, EWRAM) — так проверяем тесты. */
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
    va_start(ap, fmt);
    int64_t v = va_arg(ap, int64_t);   /* наши форматы: %lld / %s(ALIVE/DEAD) */
    va_end(ap);
    log_i64(v);
    return 0;
}

int fprintf(void *stream, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int64_t v = va_arg(ap, int64_t);
    va_end(ap);
    log_i64(v);
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
