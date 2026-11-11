#include <stddef.h>

/* Reduced model of Linux v2.6.30 tun_chr_poll; never execute this UB. */
int tun_poll_guard(int *tun) {
    int status = *tun;
    if (tun == NULL) return -1;
    return status;
}
