module rza_tests;

import std::core::dstring;

const int CASC_STEP_LIMIT = 4096;

struct CascTask {
    long[16] regs;
    int site;
}

struct CascRuntime {
    long[16] regs;
    CascCell[CASC_CELLS_MAX] cells;
    CascTask[64] queue;
    bool[CASC_SITES_MAX] pending;
    int head;
    int count;
    int pc;
    int steps;
    bool main_alive;
    bool halted;
    DString output;
    DString errors;
    int status;
}

fn bool casc_alive(CascRuntime* state, int cell) {
    assert(cell >= 0 && cell < CASC_CELLS_MAX);
    if (!state.cells[cell].published) return false;
    return !state.cells[cell].home_main || state.main_alive;
}

fn void casc_cancel(CascRuntime* state) {
    oracle_coverage.casc_cancellations++;
    oracle_coverage.casc_cancelled_tasks += (ulong)state.count;
    state.queue = {};
    state.pending = {};
    state.head = 0;
    state.count = 0;
}

fn void casc_fault(CascRuntime* state, int line, String message) {
    state.errors.appendf("FAULT line %d: %s\n", line, message);
    state.status = 1;
    casc_cancel(state);
}

fn void casc_abort(CascRuntime* state, CascSite* site, int index) {
    state.errors.appendf("ABORT line %d: cascade %s%d: dead mediator %s\n",
        site.line, site.is_async ? "a" : "c", index, casc_med_name(site.input));
    if (site.is_async) {
        oracle_coverage.casc_async_aborts++;
    } else {
        oracle_coverage.casc_sync_aborts++;
    }
}

fn void casc_exec_arith(CascRuntime* state, long[] regs, CascOp* op) {
    switch (op.code) {
        case CascOpcode.MOV_IMM: regs[op.dst] = op.literal;
        case CascOpcode.INC:
            regs[op.dst] = oracle_wrap(regs[op.dst], 1, OracleOpcode.ADD);
        case CascOpcode.DEC:
            regs[op.dst] = oracle_wrap(regs[op.dst], 1, OracleOpcode.SUB);
        case CascOpcode.ADD:
            regs[op.dst] = oracle_wrap(regs[op.left], op.literal, OracleOpcode.ADD);
        case CascOpcode.CADD:
            int128 value = (int128)regs[op.left] + (int128)op.literal;
            if (value > ORACLE_I64_MAX || value < ORACLE_I64_MIN) {
                oracle_coverage.casc_body_faults++;
                casc_fault(state, op.line, "arithmetic overflow");
                return;
            }
            regs[op.dst] = (long)value;
        default: unreachable();
    }
}

fn void casc_exec_memory(CascRuntime* state, long[] regs, CascOp* op) {
    if (!casc_alive(state, op.cell)) {
        if (state.cells[op.cell].async_out && !state.cells[op.cell].published) {
            oracle_coverage.casc_pending_faults++;
        }
        casc_fault(state, op.line,
            string::tformat("dead mediator %s", casc_med_name(op.cell)));
        return;
    }
    if (op.code == CascOpcode.LOAD) {
        regs[op.dst] = state.cells[op.cell].value;
    } else {
        state.cells[op.cell].value = regs[op.left];
    }
}

fn void casc_exec_probe(CascRuntime* state, CascOp* op) {
    bool alive = casc_alive(state, op.cell);
    if (op.cell >= 2) {
        if (alive) {
            oracle_coverage.casc_out_alive++;
        } else {
            oracle_coverage.casc_out_dead++;
        }
    }
    state.output.append(alive ? "ALIVE\n" : "DEAD\n");
}

fn void casc_exec_body(CascRuntime* state, CascSite* site, long[] regs) {
    for (int i = 0; i < site.body_len && state.status == 0; i++) {
        CascOp* op = &site.body[i];
        switch (op.code) {
            case CascOpcode.LOAD: case CascOpcode.STORE:
                casc_exec_memory(state, regs, op);
            case CascOpcode.PRINT:
                if (op.snapshot_probe) oracle_coverage.casc_snapshot_regs |= 1u << op.left;
                state.output.appendf("%d\n", regs[op.left]);
            case CascOpcode.MOV_IMM: case CascOpcode.INC: case CascOpcode.DEC:
            case CascOpcode.ADD: case CascOpcode.CADD:
                casc_exec_arith(state, regs, op);
            default: unreachable();
        }
    }
}

fn void casc_exec_sync(CascRuntime* state, CascProgram* program, int index) {
    CascSite* site = &program.sites[index];
    if (!casc_alive(state, site.input)) {
        casc_abort(state, site, index);
        return;
    }
    casc_exec_body(state, site, state.regs[..]);
    if (state.status != 0) return;
    state.cells[site.out].published = true;
    oracle_coverage.casc_sync_successes++;
}

fn void casc_exec_enqueue(CascRuntime* state, CascProgram* program, int index) {
    CascSite* site = &program.sites[index];
    if (state.pending[index]) {
        oracle_coverage.casc_repeat_faults++;
        casc_fault(state, site.line,
            string::tformat("async task a%d already pending", index));
        return;
    }
    if (!casc_alive(state, site.input)) {
        casc_abort(state, site, index);
        return;
    }
    if (state.count == state.queue.len) {
        oracle_coverage.casc_queue_full_faults++;
        casc_fault(state, site.line, "async queue full");
        return;
    }
    if (state.cells[site.out].published) oracle_coverage.casc_reenqueue_clears++;
    state.cells[site.out].published = false;
    state.cells[site.out].value = 0;
    int tail = (state.head + state.count) % (int)state.queue.len;
    state.queue[tail] = { .site = index };
    for (int reg = 0; reg < 16; reg++) state.queue[tail].regs[reg] = state.regs[reg];
    state.count++;
    state.pending[index] = true;
    oracle_coverage.casc_async_enqueues++;
}

fn long casc_run_queue(CascRuntime* state, CascProgram* program) {
    long completed = 0;
    while (state.count > 0 && state.status == 0) {
        CascTask task = state.queue[state.head];
        state.head = (state.head + 1) % (int)state.queue.len;
        state.count--;
        state.pending[task.site] = false;
        CascSite* site = &program.sites[task.site];
        if (!casc_alive(state, site.input)) {
            casc_abort(state, site, task.site);
            continue;
        }
        casc_exec_body(state, site, task.regs[..]);
        if (state.status != 0) break;
        state.cells[site.out].published = true;
        completed++;
        oracle_coverage.casc_async_successes++;
    }
    state.head = 0;
    return completed;
}

fn void casc_exec_await(CascRuntime* state, CascProgram* program, CascOp* op) {
    if (state.count == 0) oracle_coverage.casc_empty_awaits++;
    long completed = casc_run_queue(state, program);
    state.regs[op.dst] = completed;
}

fn void casc_exec_simple(CascRuntime* state, CascProgram* program, CascOp* op) {
    switch (op.code) {
        case CascOpcode.LOAD: case CascOpcode.STORE:
            casc_exec_memory(state, state.regs[..], op);
        case CascOpcode.PRINT:
            if (op.caller_probe) oracle_coverage.casc_caller_regs |= 1u << op.left;
            state.output.appendf("%d\n", state.regs[op.left]);
        case CascOpcode.PROBE: casc_exec_probe(state, op);
        case CascOpcode.MOV_IMM: case CascOpcode.INC: case CascOpcode.DEC:
        case CascOpcode.ADD: case CascOpcode.CADD:
            casc_exec_arith(state, state.regs[..], op);
        case CascOpcode.AWAIT: casc_exec_await(state, program, op);
        case CascOpcode.DECAY_MAIN: state.main_alive = false;
        case CascOpcode.MED_OUT: break;
        default: unreachable();
    }
}

fn void cascade_oracle_execute(CascProgram* program, CascRuntime* state) {
    while (!state.halted && state.status == 0) {
        assert(state.steps < CASC_STEP_LIMIT);
        assert(state.pc >= 0 && state.pc < program.len);
        state.steps++;
        CascOp* op = &program.ops[state.pc];
        state.pc++;
        switch (op.code) {
            case CascOpcode.CASC:
                CascSite* site = &program.sites[op.site];
                if (site.is_async) {
                    casc_exec_enqueue(state, program, op.site);
                } else {
                    casc_exec_sync(state, program, op.site);
                }
            case CascOpcode.BRNZ:
                bool taken = state.regs[op.left] != 0;
                oracle_cover_branch(taken, op.target < state.pc - 1);
                if (taken) state.pc = op.target;
            case CascOpcode.LABEL: break;
            case CascOpcode.RET:
                if (state.count > 0) oracle_coverage.casc_ret_drains++;
                (void)casc_run_queue(state, program);
                state.halted = true;
            default: casc_exec_simple(state, program, op);
        }
    }
}

fn OwnershipCase cascade_oracle_reference(CascProgram* program) {
    CascRuntime state = {
        .cells = program.cells,
        .main_alive = true,
        .output = dstring::temp(),
        .errors = dstring::temp(),
    };
    cascade_oracle_execute(program, &state);
    return oracle_result(state.output, state.errors, state.status);
}
