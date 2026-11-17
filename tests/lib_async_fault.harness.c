#ifndef GENERATED_RZA
#error "GENERATED_RZA must name the generated source"
#endif
#include GENERATED_RZA
#include <stdio.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

static uint64_t read_x(void) {
    uint64_t value = UINT64_MAX;
    void *cell = rza_deref_cell(rza_med_x_m());
    if (cell != NULL) memcpy(&value, cell, sizeof(value));
    return value;
}

static int enqueue_three(void) {
    ac_state_1.meds[0] = rza_med_x_m();
    ac_state_3.meds[0] = rza_med_x_m();
    ac_state_4.meds[0] = rza_med_x_m();
    c_P_bad_entryXbad_out = rez_cell_z(f_field, 8);
    c_P_later_entryXlater_out = rez_cell_z(f_field, 8);
    CHECK(c_P_bad_entryXbad_out != NULL && c_P_later_entryXlater_out != NULL);
    ac_out_gen_3++;
    ac_out_gen_4++;
    CHECK(rez_async_enqueue(&g_async, ac_run_1, &ac_state_1, &ac_pending_1));
    CHECK(rez_async_enqueue(&g_async, ac_run_3, &ac_state_3, &ac_pending_3));
    CHECK(rez_async_enqueue(&g_async, ac_run_4, &ac_state_4, &ac_pending_4));
    return 0;
}

int main(void) {
    CHECK(rza_rez3ext_abi() == 5);
    CHECK(rza_boot().code == RZA_OK);
    RzaResult enqueue = rza_enqueue_fault();
    CHECK(enqueue.code == RZA_FAULT_ARITHMETIC_OVERFLOW && enqueue.line == 11);
    CHECK(g_async.count == 0 && !ac_pending_1 && read_x() == 0);
    CHECK(rza_deref_cell(rza_med_good_out_m()) == NULL);
    printf("enqueue %u %u %llu\n", enqueue.code, enqueue.line,
        (unsigned long long)read_x());

    CHECK(enqueue_three() == 0);
    RzaAwaitResult awaited = rza_await();
    CHECK(awaited.completed == 1 && awaited.result.code == RZA_FAULT_DIVISION);
    CHECK(awaited.result.line == 25 && g_async.count == 0);
    CHECK(!ac_pending_1 && !ac_pending_3 && !ac_pending_4 && read_x() == 1);
    CHECK(rza_deref_cell(rza_med_good_out_m()) != NULL);
    CHECK(rza_deref_cell(rza_med_bad_out_m()) == NULL);
    CHECK(rza_deref_cell(rza_med_later_out_m()) == NULL);
    printf("await %u %u %llu %llu\n", awaited.result.code, awaited.result.line,
        (unsigned long long)awaited.completed, (unsigned long long)read_x());

    RezCellMed good_tail = {0};
    CHECK(rez_view_cell(rza_med_good_out_m(), 0, 4, 1, &good_tail));
    CHECK(rez_deref_cell(good_tail) != NULL);
    RzaResult cancelled = rza_enqueue_fault();
    CHECK(cancelled.code == RZA_FAULT_ARITHMETIC_OVERFLOW && cancelled.line == 11);
    CHECK(rez_deref_cell(good_tail) == NULL);
    CHECK(rza_deref_cell(rza_med_good_out_m()) == NULL && read_x() == 1);

    RzaResult recovered = rza_recover();
    CHECK(recovered.code == RZA_OK && read_x() == 2 && !ac_pending_2);
    CHECK(rza_deref_cell(rza_med_recover_out_m()) != NULL);
    printf("recover %u %llu\n", recovered.code, (unsigned long long)read_x());
    awaited = rza_await();
    CHECK(awaited.completed == 0 && awaited.result.code == RZA_OK);
    printf("empty %u %llu\n", awaited.result.code,
        (unsigned long long)awaited.completed);
    return 0;
}
