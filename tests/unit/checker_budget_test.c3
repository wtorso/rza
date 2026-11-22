module rez3asm;

fn void prepare_checker(String source) {
    init_workmem();
    reset_state();
    list_guard.freeze();
    g_lsp_mode = true;
    if (source.len > 0) run(source);
    assert(violations == 0);
    assert(lsp_diags.len() == 0);
}

fn void free_checker() {
    list_guard.deinit();
    frames.free();
    layouts.free();
    layout_fields.free();
    cells.free();
    meds.free();
    procs.free();
    cascades.free();
    blocks.free();
    labels.free();
    instrs.free();
    lsp_diags.free();
    g_state_inited = false;
    g_lsp_mode = false;
}

fn void check_capacity_diagnostic(String expected) {
    assert(violations == 1);
    assert(lsp_diags.len() == 1);
    assert(lsp_diags[0].line == 1);
    assert(lsp_diags[0].rule == "STRUCT");
    assert(lsp_diags[0].msg == expected);
}

fn void checker_procedure_capacity() @test {
    prepare_checker("");
    for (int i = 0; i < NODE_MAX; i++) procs.push({});
    open_proc("unique", 1);
    check_capacity_diagnostic("too many procedures");
    assert(procs.len() == NODE_MAX);
    free_checker();
}

fn void checker_mediator_capacity() @test {
    prepare_checker("cav main, field\nres x, main, 8\n");
    for (int i = 0; i < NODE_MAX; i++) meds.push({});
    op_med("unique_m, x, main", 1);
    check_capacity_diagnostic("too many mediators");
    assert(meds.len() == NODE_MAX);
    free_checker();
}

fn void checker_cascade_capacity() @test {
    prepare_checker("cav main, field\nres x, main, 8\nmed x_m, x, main\n");
    for (int i = 0; i < NODE_MAX; i++) cascades.push({});
    open_casc("c: x_m -> out[main]", 1, false);
    check_capacity_diagnostic("too many cascades");
    assert(cascades.len() == NODE_MAX);
    free_checker();
}

fn void checker_block_capacity() @test {
    prepare_checker("");
    for (int i = (int)blocks.len(); i < NODE_MAX; i++) blocks.push({});
    open_proc("unique", 1);
    check_capacity_diagnostic("too many blocks");
    assert(blocks.len() == NODE_MAX);
    free_checker();
}
