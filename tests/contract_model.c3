module rza_tests;

import std::io;

const int CONTRACT_PROC_COUNT = 3;
const int CONTRACT_MED_COUNT = 3;
const int CONTRACT_OP_COUNT = 14;

enum ContractAccess : char {
    UNLISTED,
    RO,
    RW,
}

enum ContractOpKind : char {
    NONE,
    LOAD,
    LOADB,
    STORE,
    STOREB,
    PROBE,
    VIEW_READ,
    VIEW_WRITE,
    GLOBAL_READ,
    GLOBAL_WRITE,
    CASC_READ,
    CASC_WRITE,
    ACASC_READ,
    ACASC_WRITE,
}

struct ContractProcedure {
    ContractAccess[CONTRACT_MED_COUNT] access;
    ContractOpKind op;
    int med;
    int call;
}

struct ContractWorld {
    ulong seed;
    ContractProcedure[CONTRACT_PROC_COUNT] procs;
}

struct ContractExpectation {
    bool valid;
    bool unlisted;
    bool call;
    int proc;
    int callee;
    String op;
    String med;
}

fn ContractWorld contract_empty_world(ulong seed) {
    ContractWorld world = { .seed = seed };
    for (int i = 0; i < CONTRACT_PROC_COUNT; i++) world.procs[i].call = -1;
    return world;
}

fn String contract_med_name(int med) {
    String[] names = { "input_m", "result_m", "global_m" };
    assert(med >= 0 && med < CONTRACT_MED_COUNT);
    return names[med];
}

fn String contract_proc_name(int proc) {
    assert(proc >= 0 && proc < CONTRACT_PROC_COUNT);
    return string::tformat("p%d", proc);
}

fn ContractAccess contract_access(ContractWorld* world, int proc, int med) {
    assert(proc >= 0 && proc < CONTRACT_PROC_COUNT);
    assert(med >= 0 && med < CONTRACT_MED_COUNT);
    return world.procs[proc].access[med];
}

fn bool contract_fail(ContractExpectation* expected, int proc, int med,
        String op, bool unlisted) {
    expected.valid = false;
    expected.unlisted = unlisted;
    expected.proc = proc;
    expected.op = op;
    expected.med = contract_med_name(med);
    return true;
}

fn bool contract_require(ContractWorld* world, int proc, int med, bool write,
        String op, ContractExpectation* expected) {
    ContractAccess actual = contract_access(world, proc, med);
    if (actual != ContractAccess.UNLISTED && (!write || actual == ContractAccess.RW)) {
        return false;
    }
    return contract_fail(expected, proc, med, op, actual == ContractAccess.UNLISTED);
}

fn bool contract_view_reference(ContractWorld* world, int proc,
        ContractExpectation* expected) {
    ContractProcedure* procedure = &world.procs[proc];
    bool write = procedure.op == ContractOpKind.VIEW_WRITE;
    if (contract_require(world, proc, procedure.med, false, "view", expected)) {
        return true;
    }
    if (!write || contract_access(world, proc, procedure.med) == ContractAccess.RW) {
        return false;
    }
    contract_fail(expected, proc, procedure.med, "store", false);
    expected.med = string::tformat("p%d_m", proc);
    return true;
}

fn bool contract_cascade_reference(ContractWorld* world, int proc,
        ContractExpectation* expected) {
    ContractProcedure* procedure = &world.procs[proc];
    if (contract_require(world, proc, procedure.med, false, "cascade", expected)) {
        return true;
    }
    bool write = procedure.op == ContractOpKind.CASC_WRITE ||
        procedure.op == ContractOpKind.ACASC_WRITE;
    if (!write || contract_access(world, proc, procedure.med) == ContractAccess.RW) {
        return false;
    }
    return contract_fail(expected, proc, procedure.med, "store", false);
}

fn bool contract_operation_reference(ContractWorld* world, int proc,
        ContractExpectation* expected) {
    ContractProcedure* procedure = &world.procs[proc];
    if (procedure.op == ContractOpKind.NONE) return false;
    if (procedure.op == ContractOpKind.VIEW_READ ||
            procedure.op == ContractOpKind.VIEW_WRITE) {
        return contract_view_reference(world, proc, expected);
    }
    if (procedure.op == ContractOpKind.CASC_READ ||
            procedure.op == ContractOpKind.CASC_WRITE ||
            procedure.op == ContractOpKind.ACASC_READ ||
            procedure.op == ContractOpKind.ACASC_WRITE) {
        return contract_cascade_reference(world, proc, expected);
    }
    bool write = procedure.op == ContractOpKind.STORE ||
        procedure.op == ContractOpKind.STOREB ||
        procedure.op == ContractOpKind.GLOBAL_WRITE;
    String[] opnames = {
        "", "load", "loadb", "store", "storeb", "probe", "", "",
        "load", "store",
    };
    return contract_require(world, proc, procedure.med, write,
        opnames[(int)procedure.op], expected);
}

fn bool contract_call_reference(ContractWorld* world, int proc,
        ContractExpectation* expected) {
    int callee = world.procs[proc].call;
    if (callee < 0) return false;
    assert(callee < proc);
    for (int med = 0; med < CONTRACT_MED_COUNT; med++) {
        ContractAccess needed = contract_access(world, callee, med);
        if (needed == ContractAccess.UNLISTED) continue;
        ContractAccess actual = contract_access(world, proc, med);
        if (actual == ContractAccess.RW || actual == needed) continue;
        contract_fail(expected, proc, med, "call", actual == ContractAccess.UNLISTED);
        expected.call = true;
        expected.callee = callee;
        return true;
    }
    return false;
}

fn ContractExpectation contract_reference(ContractWorld* world) {
    ContractExpectation expected = { .valid = true, .callee = -1 };
    for (int proc = 0; proc < CONTRACT_PROC_COUNT; proc++) {
        if (contract_operation_reference(world, proc, &expected)) return expected;
        if (contract_call_reference(world, proc, &expected)) return expected;
    }
    return expected;
}

fn String contract_diagnostic(ContractExpectation expected) {
    DString text = dstring::temp();
    text.appendf("proc p%d: ", expected.proc);
    if (expected.call && expected.unlisted) {
        text.appendf("call uses unlisted mediator %s (callee p%d)",
            expected.med, expected.callee);
    } else if (expected.call) {
        text.appendf("call requires rw access to %s (callee p%d)",
            expected.med, expected.callee);
    } else {
        text.appendf("%s via %s mediator %s", expected.op,
            expected.unlisted ? "unlisted" : "read-only", expected.med);
    }
    return text.str_view();
}

fn int contract_model_selftest() {
    ContractWorld world = contract_empty_world(1);
    if (!expect(contract_reference(&world).valid, "model accepts pure procedures")) return 1;
    world.procs[0].op = ContractOpKind.LOAD;
    world.procs[0].access[0] = ContractAccess.RO;
    if (!expect(contract_reference(&world).valid, "model accepts ro load")) return 1;
    world.procs[0].op = ContractOpKind.STORE;
    if (!expect(!contract_reference(&world).valid, "model rejects ro store")) return 1;
    world.procs[0].access[0] = ContractAccess.RW;
    if (!expect(contract_reference(&world).valid, "model accepts rw store")) return 1;
    world.procs[0].access[0] = ContractAccess.UNLISTED;
    ContractExpectation failure = contract_reference(&world);
    if (!expect(!failure.valid && failure.unlisted && failure.med == "input_m",
            "model identifies an unlisted write")) return 1;
    world = contract_empty_world(2);
    world.procs[0].access[1] = ContractAccess.RW;
    world.procs[1].access[1] = ContractAccess.RO;
    world.procs[1].call = 0;
    failure = contract_reference(&world);
    if (!expect(!failure.valid && failure.call && failure.proc == 1 &&
            failure.callee == 0 && failure.med == "result_m",
            "model rejects transitive escalation")) return 1;
    world.procs[1].access[1] = ContractAccess.RW;
    if (!expect(contract_reference(&world).valid, "model accepts rw call chain")) return 1;
    return 0;
}
