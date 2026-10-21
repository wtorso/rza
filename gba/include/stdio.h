/* stdio.h — bare-metal заглушка для сгенерированного кода (.rza → C99):
 * объявления достаточны; реализация — gba/harness.c (лог в EWRAM). */
#ifndef RZN_GBA_STDIO_H
#define RZN_GBA_STDIO_H
#include <stdint.h>
#ifndef RZN_GBA_TYPES
#define RZN_GBA_TYPES
typedef __SIZE_TYPE__ rzn_size_t;
typedef __SIZE_TYPE__ size_t;
#define NULL ((void*)0)
#endif
int printf(const char *fmt, ...);
int fprintf(void *stream, const char *fmt, ...);
#define stderr ((void*)0)
#endif
