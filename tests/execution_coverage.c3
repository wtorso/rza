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

fn void oracle_coverage_print() {
    io::printfn("ORACLE_COVERAGE success=%d fault=%d checked=%d bounds=%d",
        oracle_coverage.successes, oracle_coverage.faults,
        oracle_coverage.checked_overflows, oracle_coverage.bounds_faults);
    io::printfn("ORACLE_BRANCHES taken=%d fallthrough=%d forward=%d backward=%d",
        oracle_coverage.branch_taken, oracle_coverage.branch_fallthrough,
        oracle_coverage.forward_taken, oracle_coverage.backward_taken);
}
