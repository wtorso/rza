module rza_tests;

import std::io;

const int ORACLE_OPCODE_COUNT = 27;

struct OracleCoverage {
    ulong[ORACLE_OPCODE_COUNT] opcodes;
    ulong successes;
    ulong faults;
    ulong checked_overflows;
    ulong division_faults;
    ulong shift_faults;
    ulong bounds_faults;
    ulong view_constructions;
    ulong nested_views;
    ulong view_faults;
    ulong branch_taken;
    ulong branch_fallthrough;
    ulong forward_taken;
    ulong backward_taken;
    ulong proc_calls;
    ulong nested_proc_calls;
    ulong proc_returns;
    ulong proc_reentries;
    ulong proc_local_loads;
    ulong proc_local_stores;
    ulong proc_arena_faults;
    ulong proc_dead_after_ret;
    uint proc_entry_regs;
    uint proc_restore_regs;
    ulong casc_sync_successes;
    ulong casc_sync_aborts;
    ulong casc_async_enqueues;
    ulong casc_async_successes;
    ulong casc_async_aborts;
    ulong casc_pending_faults;
    ulong casc_repeat_faults;
    ulong casc_queue_full_faults;
    ulong casc_body_faults;
    ulong casc_out_alive;
    ulong casc_out_dead;
    ulong casc_empty_awaits;
    ulong[9] cascade_cases;
    uint casc_snapshot_regs;
    uint casc_caller_regs;
    ulong casc_ret_drains;
    ulong casc_reenqueue_clears;
}

OracleCoverage oracle_coverage;

fn void oracle_coverage_reset() {
    oracle_coverage = {};
}

fn void oracle_cover_branch(bool taken, bool backward) {
    if (taken) {
        oracle_coverage.branch_taken++;
        if (backward) {
            oracle_coverage.backward_taken++;
        } else {
            oracle_coverage.forward_taken++;
        }
        return;
    }
    oracle_coverage.branch_fallthrough++;
}

fn bool oracle_coverage_ok() {
    if (!expect(oracle_coverage.successes > 0 && oracle_coverage.faults > 0,
            "oracle needs both successful and failing executions")) return false;
    if (!expect(oracle_coverage.checked_overflows > 0 && oracle_coverage.bounds_faults > 0,
            "oracle needs checked and bounds faults")) return false;
    if (!expect(oracle_coverage.division_faults > 0 && oracle_coverage.shift_faults > 0,
            "oracle needs division and shift faults")) return false;
    if (!expect(oracle_coverage.branch_taken > 0 && oracle_coverage.branch_fallthrough > 0,
            "oracle needs taken and untaken branches")) return false;
    if (!expect(oracle_coverage.forward_taken > 0 && oracle_coverage.backward_taken > 0,
            "oracle needs forward and backward taken branches")) return false;
    if (!expect(oracle_coverage.view_constructions >= 5 && oracle_coverage.nested_views > 0
            && oracle_coverage.view_faults >= 2,
            "oracle needs valid, nested, empty and invalid views")) return false;
    OracleOpcode[] required = {
        OracleOpcode.MOV_IMM, OracleOpcode.MOV_REG, OracleOpcode.ADD,
        OracleOpcode.SUB, OracleOpcode.MUL, OracleOpcode.CADD,
        OracleOpcode.CSUB, OracleOpcode.CMUL, OracleOpcode.DIV, OracleOpcode.MOD,
        OracleOpcode.SHL, OracleOpcode.SHR, OracleOpcode.USHR,
        OracleOpcode.SLT, OracleOpcode.AND, OracleOpcode.LOAD, OracleOpcode.STORE,
        OracleOpcode.PRINT, OracleOpcode.INC, OracleOpcode.DEC,
        OracleOpcode.CINC, OracleOpcode.CDEC,
        OracleOpcode.LABEL, OracleOpcode.BRZ, OracleOpcode.BRNZ,
        OracleOpcode.VIEW, OracleOpcode.RET,
    };
    assert(required.len == ORACLE_OPCODE_COUNT);
    for (sz i = 0; i < required.len; i++) {
        if (!expect(oracle_coverage.opcodes[(int)required[i]] > 0,
                "oracle opcode was never executed")) return false;
    }
    return true;
}

fn bool proc_oracle_coverage_ok() {
    if (!expect(oracle_coverage.proc_calls > 0 && oracle_coverage.nested_proc_calls > 0,
            "proc oracle needs top-level and nested calls")) return false;
    if (!expect(oracle_coverage.proc_returns > 0 && oracle_coverage.proc_reentries > 0,
            "proc oracle needs returns and reentries")) return false;
    if (!expect(oracle_coverage.proc_local_loads > 0 && oracle_coverage.proc_local_stores > 0,
            "proc oracle needs local memory reads and writes")) return false;
    if (!expect(oracle_coverage.proc_arena_faults > 0,
            "proc oracle needs arena exhaustion")) return false;
    if (!expect(oracle_coverage.proc_dead_after_ret > 0,
            "proc oracle needs dead-after-return faults")) return false;
    if (!expect(oracle_coverage.proc_entry_regs == 0xFFFF &&
            oracle_coverage.proc_restore_regs == 0xFFFF,
            "proc oracle needs all sixteen entry and restored registers")) return false;
    return true;
}

fn bool cascade_oracle_coverage_ok() {
    if (!expect(oracle_coverage.casc_sync_successes > 0 &&
            oracle_coverage.casc_sync_aborts > 0,
            "cascade oracle needs sync success and abort")) return false;
    if (!expect(oracle_coverage.casc_async_enqueues > 0 &&
            oracle_coverage.casc_async_successes > 0 &&
            oracle_coverage.casc_async_aborts > 0,
            "cascade oracle needs async enqueue, success and abort")) return false;
    if (!expect(oracle_coverage.casc_pending_faults > 0 &&
            oracle_coverage.casc_repeat_faults > 0 &&
            oracle_coverage.casc_queue_full_faults > 0 &&
            oracle_coverage.casc_body_faults > 0,
            "cascade oracle needs pending, repeat, queue and body faults")) return false;
    if (!expect(oracle_coverage.casc_out_alive > 0 && oracle_coverage.casc_out_dead > 0,
            "cascade oracle needs live and unpublished outputs")) return false;
    if (!expect(oracle_coverage.casc_empty_awaits > 0,
            "cascade oracle needs an empty await")) return false;
    if (!expect(oracle_coverage.casc_snapshot_regs == 0xFFFF &&
            oracle_coverage.casc_caller_regs == 0xFFFB,
            "cascade oracle needs async snapshot and caller registers")) return false;
    if (!expect(oracle_coverage.casc_ret_drains > 0 &&
            oracle_coverage.casc_reenqueue_clears > 0,
            "cascade oracle needs ret drain and reenqueue clearing")) return false;
    for (int scenario = 0; scenario < 9; scenario++) {
        if (!expect(oracle_coverage.cascade_cases[scenario] == 4,
                "cascade oracle needs four passing programs per scenario")) return false;
    }
    return true;
}

fn void oracle_coverage_print() {
    io::printfn("ORACLE_COVERAGE success=%d fault=%d checked=%d bounds=%d",
        oracle_coverage.successes, oracle_coverage.faults,
        oracle_coverage.checked_overflows, oracle_coverage.bounds_faults);
    io::printfn("ORACLE_ARITH division=%d shift=%d",
        oracle_coverage.division_faults, oracle_coverage.shift_faults);
    io::printfn("ORACLE_VIEWS constructed=%d nested=%d fault=%d",
        oracle_coverage.view_constructions, oracle_coverage.nested_views,
        oracle_coverage.view_faults);
    io::printfn("ORACLE_BRANCHES taken=%d fallthrough=%d forward=%d backward=%d",
        oracle_coverage.branch_taken, oracle_coverage.branch_fallthrough,
        oracle_coverage.forward_taken, oracle_coverage.backward_taken);
    io::printfn("ORACLE_PROC calls=%d nested=%d returns=%d reentries=%d",
        oracle_coverage.proc_calls, oracle_coverage.nested_proc_calls,
        oracle_coverage.proc_returns, oracle_coverage.proc_reentries);
    io::printfn("ORACLE_PROC_MEMORY loads=%d stores=%d arena=%d dead_after_ret=%d",
        oracle_coverage.proc_local_loads, oracle_coverage.proc_local_stores,
        oracle_coverage.proc_arena_faults, oracle_coverage.proc_dead_after_ret);
    io::printfn("ORACLE_PROC_REGISTERS entry=%d restore=%d",
        oracle_coverage.proc_entry_regs, oracle_coverage.proc_restore_regs);
    io::printfn("ORACLE_CASC sync=%d sync_abort=%d enqueue=%d async=%d abort=%d",
        oracle_coverage.casc_sync_successes, oracle_coverage.casc_sync_aborts,
        oracle_coverage.casc_async_enqueues, oracle_coverage.casc_async_successes,
        oracle_coverage.casc_async_aborts);
    io::printfn("ORACLE_CASC_FAULT pending=%d repeat=%d full=%d body=%d",
        oracle_coverage.casc_pending_faults, oracle_coverage.casc_repeat_faults,
        oracle_coverage.casc_queue_full_faults, oracle_coverage.casc_body_faults);
    io::printfn("ORACLE_CASC_OUT alive=%d dead=%d empty_await=%d",
        oracle_coverage.casc_out_alive, oracle_coverage.casc_out_dead,
        oracle_coverage.casc_empty_awaits);
    io::printfn("ORACLE_CASC_REGISTERS snapshot=%d caller=%d ret_drain=%d reenqueue=%d",
        oracle_coverage.casc_snapshot_regs, oracle_coverage.casc_caller_regs,
        oracle_coverage.casc_ret_drains, oracle_coverage.casc_reenqueue_clears);
}
