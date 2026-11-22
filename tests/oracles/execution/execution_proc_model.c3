module rza_tests;

import libc;
import std::core::dstring;

const int PROC_ORACLE_STEP_LIMIT = 4096;

struct ProcFrame {
    long[16] regs;
    char[64] local_cells;
    int used;
    int proc;
    int pc;
}

struct ProcRuntime {
    ProcFrame[3] frames;
    int depth;
    char[64] global_cells;
    bool[PROC_ORACLE_PROCS_MAX] returned;
    DString output;
    DString errors;
    int status;
    int steps;
}

fn ProcOp* proc_current_op(ProcProgram* program, ProcFrame* frame) {
    if (frame.proc < 0) {
        assert(frame.pc >= 0 && frame.pc < program.top_len);
        return &program.top[frame.pc];
    }
    assert(frame.proc >= 0 && frame.proc < program.proc_count);
    assert(frame.pc >= 0 && frame.pc < program.procs[frame.proc].len);
    return &program.procs[frame.proc].ops[frame.pc];
}

fn void proc_fail(ProcRuntime* state, ProcOp* op, String message) {
    state.errors.appendf("FAULT line %d: %s\n", op.line, message);
    state.status = 1;
}

fn void proc_exec_call(ProcRuntime* state, ProcFrame* caller, ProcOp* op) {
    assert(op.target >= 0 && op.target < PROC_ORACLE_PROCS_MAX);
    assert(caller.proc < 0 || op.target < caller.proc);
    assert(state.depth > 0 && state.depth < state.frames.len);
    oracle_coverage.proc_calls++;
    if (caller.proc >= 0) oracle_coverage.nested_proc_calls++;
    if (state.returned[op.target]) oracle_coverage.proc_reentries++;
    state.frames[state.depth] = { .proc = op.target };
    state.depth++;
}

fn void proc_exec_res(ProcRuntime* state, ProcFrame* frame, ProcOp* op) {
    assert(op.home == frame.proc && op.dst == 64);
    if (frame.used != 0) {
        oracle_coverage.proc_arena_faults++;
        proc_fail(state, op, string::tformat("arena overflow (cell p%d_cell)", op.home));
        return;
    }
    frame.used = op.dst;
    libc::memset(&frame.local_cells[0], 0, frame.local_cells.len);
}

fn char[] proc_active_cells(ProcRuntime* state, int home) {
    if (home < 0) return state.global_cells[..];
    for (int i = 0; i < state.depth; i++) {
        if (state.frames[i].proc == home) return state.frames[i].local_cells[..];
    }
    return {};
}

fn String proc_reference_med(ProcOp* op, bool top_level) {
    if (op.home < 0) return "cells_m";
    if (top_level) return string::tformat("p%d_dead_m", op.home);
    return string::tformat("p%d_m", op.home);
}

fn void proc_exec_memory(ProcRuntime* state, ProcFrame* frame, ProcOp* op) {
    char[] cells = proc_active_cells(state, op.home);
    bool top_level = frame.proc < 0;
    String med = proc_reference_med(op, top_level);
    if (cells.len == 0) {
        if (op.home >= 0 && state.returned[op.home]) {
            oracle_coverage.proc_dead_after_ret++;
        }
        proc_fail(state, op, string::tformat("dead mediator %s", med));
        return;
    }
    long offset = op.literal_rhs ? op.literal : frame.regs[op.right];
    if (offset < 0 || offset > 56) {
        oracle_coverage.bounds_faults++;
        proc_fail(state, op, string::tformat("out of bounds %s", med));
        return;
    }
    if (op.code == ProcOpcode.LOAD) {
        if (op.home >= 0) oracle_coverage.proc_local_loads++;
        libc::memcpy(&frame.regs[op.dst], &cells[(sz)offset], 8);
        return;
    }
    if (op.home >= 0) oracle_coverage.proc_local_stores++;
    libc::memcpy(&cells[(sz)offset], &frame.regs[op.left], 8);
}

fn long proc_wrap(long left, long right, ProcOpcode code) {
    OracleOpcode wrapped = OracleOpcode.ADD;
    if (code == ProcOpcode.SUB) wrapped = OracleOpcode.SUB;
    if (code == ProcOpcode.MUL) wrapped = OracleOpcode.MUL;
    return oracle_wrap(left, right, wrapped);
}

fn void proc_exec_alu(ProcFrame* frame, ProcOp* op) {
    long left = frame.regs[op.left];
    long right = op.literal_rhs ? op.literal : frame.regs[op.right];
    if (op.code == ProcOpcode.SLT) {
        frame.regs[op.dst] = left < right ? 1 : 0;
        return;
    }
    if (op.code == ProcOpcode.AND) {
        frame.regs[op.dst] = left & right;
        return;
    }
    frame.regs[op.dst] = proc_wrap(left, right, op.code);
}

fn void proc_exec_simple(ProcRuntime* state, ProcFrame* frame, ProcOp* op) {
    switch (op.code) {
        case ProcOpcode.MOV_IMM: frame.regs[op.dst] = op.literal;
        case ProcOpcode.MOV_REG: frame.regs[op.dst] = frame.regs[op.left];
        case ProcOpcode.ADD: case ProcOpcode.SUB: case ProcOpcode.MUL:
        case ProcOpcode.SLT: case ProcOpcode.AND:
            proc_exec_alu(frame, op);
        case ProcOpcode.PRINT:
            if (op.entry_probe) oracle_coverage.proc_entry_regs |= 1u << op.left;
            if (op.restore_probe) oracle_coverage.proc_restore_regs |= 1u << op.left;
            state.output.appendf("%d\n", frame.regs[op.left]);
        case ProcOpcode.INC:
            frame.regs[op.dst] = oracle_wrap(frame.regs[op.dst], 1, OracleOpcode.ADD);
        case ProcOpcode.DEC:
            frame.regs[op.dst] = oracle_wrap(frame.regs[op.dst], 1, OracleOpcode.SUB);
        case ProcOpcode.LABEL: break;
        default: unreachable();
    }
}

fn void proc_exec_branch(ProcFrame* frame, ProcOp* op) {
    bool taken = frame.regs[op.left] != 0;
    oracle_cover_branch(taken, true);
    if (taken) frame.pc = op.target;
}

fn void proc_exec_ret(ProcRuntime* state, ProcFrame* frame) {
    if (frame.proc < 0) {
        state.depth = 0;
        return;
    }
    state.returned[frame.proc] = true;
    oracle_coverage.proc_returns++;
    state.depth--;
}

fn void proc_oracle_execute(ProcProgram* program, ProcRuntime* state) {
    while (state.depth > 0 && state.status == 0) {
        assert(state.steps < PROC_ORACLE_STEP_LIMIT);
        state.steps++;
        ProcFrame* frame = &state.frames[state.depth - 1];
        ProcOp* op = proc_current_op(program, frame);
        frame.pc++;
        switch (op.code) {
            case ProcOpcode.CALL: proc_exec_call(state, frame, op);
            case ProcOpcode.RES: proc_exec_res(state, frame, op);
            case ProcOpcode.LOAD: case ProcOpcode.STORE:
                proc_exec_memory(state, frame, op);
            case ProcOpcode.BRNZ: proc_exec_branch(frame, op);
            case ProcOpcode.RET: proc_exec_ret(state, frame);
            default: proc_exec_simple(state, frame, op);
        }
    }
}

fn OwnershipCase proc_oracle_reference(ProcProgram* program) {
    ProcRuntime state = {
        .depth = 1,
        .output = dstring::temp(),
        .errors = dstring::temp(),
    };
    state.frames[0].proc = -1;
    proc_oracle_execute(program, &state);
    return oracle_result(state.output, state.errors, state.status);
}
