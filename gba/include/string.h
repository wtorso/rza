/* string.h — bare-metal: memset реализован в harness.c */
#ifndef RZN_GBA_STRING_H
#define RZN_GBA_STRING_H
#include <stdint.h>
#ifndef RZN_GBA_TYPES
#define RZN_GBA_TYPES
typedef __SIZE_TYPE__ rzn_size_t;
typedef __SIZE_TYPE__ size_t;
#define NULL ((void*)0)
#endif
void *memset(void *d, int c, size_t n);
#endif
