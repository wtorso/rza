#include <stdio.h>
#include "rez3ext.h"

extern void rza_boot(void);
extern void rza_setup(void);
extern RezCavity *rza_frame_main(void);
extern RezCavity *rza_frame_tmp(void);
extern RezCellMed rza_med_x_m(void);

int main(void) {
    RezCellMed m;
    (void)&rez_decay; (void)&rez_arena_alloc_z; (void)&rez_cell_z;
    (void)&rez_issue_cell; (void)&rez_deref_cell; (void)&rez_cell_bounds;
    (void)&rez_frame_reset; (void)&rez_cav_enter; (void)&rez_i64_add;
    (void)&rez_i64_sub; (void)&rez_i64_mul; (void)&rez_i64_div;
    (void)&rez_i64_mod; (void)&rez_i64_shl; (void)&rez_i64_shr;
    (void)&rez_i64_ushr;
    (void)&rez_i64_cadd; (void)&rez_i64_csub; (void)&rez_i64_cmul;
    rza_boot();
    rza_setup();
    m = rza_med_x_m();
    if (m.owner != rza_frame_main()) return 10;
    if (m.home != rza_frame_tmp()) return 11;
    printf("owner ok\n");
    return 0;
}
