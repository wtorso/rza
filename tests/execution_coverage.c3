module rza_tests;

import std::io;

const int ORACLE_OPCODE_COUNT = 19;

struct OracleCoverage {
    ulong[ORACLE_OPCODE_COUNT] opcodes;
    ulong successes;
    ulong faults;
    ulong checked_overflows;
    ulong bounds_faults;
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
    if (!expect(oracle_coverage.branch_taken > 0 && oracle_coverage.branch_fallthrough > 0,
            "oracle needs taken and untaken branches")) return false;
    if (!expect(oracle_coverage.forward_taken > 0 && oracle_coverage.backward_taken > 0,
            "oracle needs forward and backward taken branches")) return false;
    OracleOpcode[] required = {
        OracleOpcode.MOV_IMM, OracleOpcode.MOV_REG, OracleOpcode.ADD,
        OracleOpcode.SUB, OracleOpcode.MUL, OracleOpcode.CADD,
        OracleOpcode.CSUB, OracleOpcode.CMUL, OracleOpcode.SLT,
        OracleOpcode.AND, OracleOpcode.LOAD, OracleOpcode.STORE,
        OracleOpcode.PRINT, OracleOpcode.INC, OracleOpcode.DEC,
        OracleOpcode.LABEL, OracleOpcode.BRZ, OracleOpcode.BRNZ, OracleOpcode.RET,
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

fn void oracle_coverage_print() {
    io::printfn("ORACLE_COVERAGE success=%d fault=%d checked=%d bounds=%d",
        oracle_coverage.successes, oracle_coverage.faults,
        oracle_coverage.checked_overflows, oracle_coverage.bounds_faults);
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
}
