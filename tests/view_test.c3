module rez3asm;

fn void view_declarations_and_extents() @test {
    prepare_checker("res raw, field, 32\nmed raw_m, raw, field\n"
        "layout Entry: key:i64, value:i64\nres entries, field, Entry[4]\n"
        "med entries_m, entries, field\nview raw_v_m, raw_m, %r0, 8\n"
        "view nested_m, raw_v_m, 2, 3\nview entries_v_m, entries_m, 1, 2\n");
    assert(meds.len() == 5);
    assert(meds[0].view_source == -1 && meds[0].extent == 32);
    assert(meds[1].view_source == -1 && meds[1].extent == 4);
    assert(meds[2].view_source == 0 && meds[2].extent == 8);
    assert(meds[2].view_offset.reg == 0);
    assert(meds[2].view_offset.operand_kind == OperandKind.REGISTER);
    assert(meds[2].view_length.operand_kind == OperandKind.IMMEDIATE);
    assert(meds[2].view_length.immediate.bits == 8);
    assert(meds[3].view_source == 2 && meds[3].extent == 3);
    assert(meds[4].view_source == 1 && meds[4].extent == 2);
    assert(cells[0].med_count == 3 && cells[1].med_count == 2);
    assert(instrs[instrs.len() - 1].op == Op.VIEW);
    free_checker();
}

fn void view_dynamic_parent_and_source_decay() @test {
    prepare_checker("res raw, field, 32\nmed raw_m, raw, field\n"
        "view parent_m, raw_m, 0, %r0\nview child_m, parent_m, 1, 4\n"
        "cav tmp, field\nres gone, tmp, 8\nmed gone_m, gone, tmp\n"
        "decay tmp\nview dead_view_m, gone_m, 0, 1\n");
    assert(meds[1].extent == -1 && meds[2].extent == 4);
    assert(meds[4].view_source == 3);
    free_checker();
}

fn void view_access_uses_destination_extent() @test {
    expect_layout_error("res raw, field, 32\nmed raw_m, raw, field\n"
        "view raw_v_m, raw_m, %r0, 4\nload %r1, [raw_v_m + 7]\n", 4,
        "STRUCT", "load out of bounds via raw_v_m");
    expect_layout_error("layout Entry: key:i64\nres entries, field, Entry[4]\n"
        "med entries_m, entries, field\nview entries_v_m, entries_m, %r0, 2\n"
        "load %r1, [entries_v_m + 2].key\n", 5,
        "STRUCT", "load element index out of bounds");
}

fn void view_dynamic_length_still_rejects_index_beyond_cell() @test {
    expect_layout_error("layout Entry: key:i64\nres entries, field, Entry[2]\n"
        "med entries_m, entries, field\nview entries_v_m, entries_m, 0, %r0\n"
        "load %r1, [entries_v_m + 2].key\n", 5,
        "STRUCT", "load element index out of bounds");
}

fn void view_declaration_diagnostics() @test {
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "view missing_source_m, absent_m, 0, 1\n", 3,
        "STRUCT", "view via unknown mediator absent_m");
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "view raw_v_m, raw_m, nope, 1\n", 3,
        "STRUCT", "bad view operand nope (want i64 or register)");
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "view raw_v_m, raw_m, -1, 1\n", 3,
        "STRUCT", "view range out of bounds raw_v_m");
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "view raw_v_m, raw_m, 7, 2\n", 3,
        "STRUCT", "view range out of bounds raw_v_m");
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "view raw_m, raw_m, 0, 1\n", 3, "DUP", "duplicate name raw_m");
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "view bad, raw_m, 0, 1\n", 3,
        "STRUCT", "mediator name bad must end with _m");
}

fn void view_cascade_and_capacity_diagnostics() @test {
    prepare_checker("res raw, field, 32\nmed raw_m, raw, field\n"
        "casc c: raw_m -> out[field]\nview raw_v_m, raw_m, 8, 8\n"
        "view nested_m, raw_v_m, 4, 4\nloadb %r0, [nested_m + 0]\nendc\n");
    assert(meds[1].cascade == 0 && meds[2].cascade == 0);
    free_checker();
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "acasc c: raw_m -> out\nview raw_v_m, raw_m, 0, 1\nendc\n", 4,
        "STRUCT", "op view not allowed in async cascade body (data instructions only)");
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "casc c: raw_m -> out[field]\nview raw_v_m, raw_m, 0, 1\nendc\n"
        "loadb %r0, [raw_v_m + 0]\n", 6,
        "SCOPE", "mediator raw_v_m is not visible outside its cascade");
    prepare_checker("res raw, field, 8\nmed raw_m, raw, field\n");
    cells[0].med_count = CELL_MED_MAX;
    op_view("raw_v_m, raw_m, 0, 1", 1);
    check_capacity_diagnostic("too many mediators for one cell");
    assert(meds.len() == 1 && instrs.len() == 2);
    free_checker();
}

fn void view_failed_declaration_is_atomic() @test {
    start_invalid_layout("res raw, field, 8\nmed raw_m, raw, field\n"
        "view raw_v_m, raw_m, 0, 9\n");
    assert(violations == 1 && meds.len() == 1);
    assert(cells[0].med_count == 1 && instrs.len() == 2);
    free_checker();
}
