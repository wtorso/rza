module rez3asm;

import std::core::dstring;

fn void layout_entry_size_and_offsets() @test {
    prepare_checker("layout Entry: key:i64, value:i64\n"
        "res entries, field, Entry[512]\nres raw, field, 8\n");
    assert(layouts.len() == 1);
    assert(layout_fields.len() == 2);
    assert(layouts[0].size_bytes == 16);
    assert(layouts[0].alignment_bytes == 8);
    assert(layout_fields[0].offset_bytes == 0);
    assert(layout_fields[1].offset_bytes == 8);
    assert(cells[0].layout == 0);
    assert(cells[0].element_count == 512);
    assert(cells[0].size == 8192);
    assert(cells[1].layout == -1);
    assert(cells[1].element_count == 0);
    free_checker();
}

fn void layout_pair_padding_and_u8() @test {
    prepare_checker("layout Pair: tag:u8, value:i64\nres pairs, field, Pair[2]\n");
    assert(layouts[0].size_bytes == 16);
    assert(layouts[0].alignment_bytes == 8);
    assert(layout_fields[0].scalar_type == ScalarType.U8);
    assert(layout_fields[1].scalar_type == ScalarType.I64);
    assert(layout_fields[0].offset_bytes == 0);
    assert(layout_fields[1].offset_bytes == 8);
    assert(cells[0].size == 32);
    free_checker();
}

fn void layout_scalar_and_shared_field_names() @test {
    prepare_checker("layout Entry: key:i64, value:i64\n"
        "layout Other: value:i64\nres single, field, Entry\n"
        "res one, field, Entry[1]\nres other, field, Other\n");
    assert(cells[0].element_count == 1);
    assert(cells[0].size == 16);
    assert(cells[1].element_count == 1);
    assert(cells[1].size == 16);
    int entry = find_layout("Entry");
    int other = find_layout("Other");
    assert(entry >= 0 && other >= 0 && entry != other);
    int entry_value = find_layout_field(entry, "value");
    int other_value = find_layout_field(other, "value");
    assert(entry_value >= 0 && other_value >= 0);
    assert(entry_value != other_value);
    assert(layout_fields[entry_value].name == "value");
    assert(layout_fields[other_value].name == "value");
    free_checker();
}

fn void layout_state_reset() @test {
    prepare_checker("layout Entry: key:i64, value:i64\n");
    assert(layouts.len() == 1);
    reset_state();
    assert(layouts.len() == 0);
    assert(layout_fields.len() == 0);
    assert(layout_map.count == 0);
    free_checker();
    assert(!g_state_inited);
}

fn void layout_offset_expression_capacity() @test {
    prepare_checker("layout Entry: key:i64, value:i64\n"
        "res entries, field, Entry\nmed entries_m, entries, field\n");
    layouts[0].size_bytes = CELL_SIZE_BYTES_MAX;
    Instr ins = { .x = 0, .y = 1, .c = 15, .scalar_type = ScalarType.I64 };
    DString out = dstring::new(workmem);
    defer out.free();
    append_access_offset(&out, &ins);
    assert(out.str_view() == "(uint64_t)r15 * 2147483632 + 8");
    assert(out.len() < OFFSET_STRING_BYTES);
    free_checker();
}

fn void start_invalid_layout(String source) {
    init_workmem();
    reset_state();
    list_guard.freeze();
    g_lsp_mode = true;
    run(source);
}

fn void expect_layout_error(String source, int line, String rule, String message) {
    start_invalid_layout(source);
    assert(violations == 1);
    assert(lsp_diags.len() == 1);
    assert(lsp_diags[0].line == line);
    assert(lsp_diags[0].rule == rule);
    assert(lsp_diags[0].msg == message);
    free_checker();
}

fn void layout_declaration_diagnostics() @test {
    expect_layout_error("layout Broken\n", 1, "STRUCT",
        "malformed layout declaration");
    expect_layout_error("layout entry: key:i64\n", 1, "STRUCT",
        "bad layout name entry");
    expect_layout_error("layout Bad: value:u64\n", 1, "STRUCT",
        "unknown layout scalar type u64");
    expect_layout_error("layout Entry: key:i64\nlayout Entry: value:i64\n",
        2, "DUP", "duplicate layout Entry");
    expect_layout_error("layout Entry: key:i64, key:i64\n", 1, "DUP",
        "duplicate layout field key");
    expect_layout_error("res x, field, Later\nlayout Later: key:i64\n", 1,
        "STRUCT", "unknown layout Later");
    expect_layout_error("layout Entry: key:i64\nres x, field, Entry[0]\n",
        2, "STRUCT", "bad layout element count 0");
    expect_layout_error("layout Entry: key:i64\nres x, field, Entry[-1]\n",
        2, "STRUCT", "bad layout element count -1");
    expect_layout_error("layout Entry: key:i64\nres x, field, Entry[1\n",
        2, "STRUCT", "malformed layout use Entry[1");
    expect_layout_error("layout Entry: key:i64\nres x, field, Entry[2147483647]\n",
        2, "STRUCT", "typed cell size out of i32 range");
}

fn void layout_access_diagnostics() @test {
    String prefix = "layout Entry: key:i64, value:i64\n"
        "res entries, field, Entry[2]\nmed entries_m, entries, field\n";
    DString source = dstring::temp(prefix);
    source.append("load %r0, [entries_m + 0]\n");
    expect_layout_error(source.str_view(), 4, "STRUCT",
        "typed cell requires field selector in load");
    source = dstring::temp(prefix);
    source.append("load %r0, [entries_m + 0].missing\n");
    expect_layout_error(source.str_view(), 4, "STRUCT",
        "unknown layout field missing");
    source = dstring::temp(prefix);
    source.append("loadb %r0, [entries_m + 0].key\n");
    expect_layout_error(source.str_view(), 4, "STRUCT",
        "opcode does not match layout field key");
    source = dstring::temp(prefix);
    source.append("load %r0, [entries_m + 2].key\n");
    expect_layout_error(source.str_view(), 4, "STRUCT",
        "load element index out of bounds");
    source = dstring::temp(prefix);
    source.append("load %r0, [entries_m + 0].key.extra\n");
    expect_layout_error(source.str_view(), 4, "STRUCT",
        "bad memory operand [entries_m + 0].key.extra "
        "(want [med + off] or [med + index].field)");
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "load %r0, [raw_m + 0].key\n", 3, "STRUCT",
        "field access requires typed cell");
}

fn void layout_scope_diagnostics() @test {
    expect_layout_error("proc p:\nlayout Entry: key:i64\nret\n", 2,
        "STRUCT", "layout declaration must be top-level");
    expect_layout_error("ret\nlayout Entry: key:i64\n", 2,
        "STRUCT", "code after top-level ret");
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "casc c: raw_m -> out[field]\nlayout Entry: key:i64\nendc\nret\n",
        4, "STRUCT", "op layout not allowed in cascade body (data instructions only)");
}

fn void layout_declaration_failure_is_atomic() @test {
    start_invalid_layout("layout Entry: key:i64, key:i64\n");
    assert(violations == 1);
    assert(layouts.len() == 0);
    assert(layout_fields.len() == 0);
    assert(layout_map.count == 0);
    free_checker();
}

fn void layout_failed_res_does_not_create_cell() @test {
    start_invalid_layout("res x, missing, Missing\n");
    assert(violations == 1 && cells.len() == 0);
    free_checker();
    start_invalid_layout("layout Entry: key:i64\nres x, missing, Entry\n");
    assert(violations == 1 && cells.len() == 0);
    assert(lsp_diags[0].rule == "I1");
    free_checker();
}

fn void layout_field_count_boundaries() @test {
    DString declaration = dstring::temp("layout Entry: f0:i64");
    defer declaration.free();
    for (int i = 1; i < 64; i++) declaration.appendf(", f%d:i64", i);
    prepare_checker(declaration.str_view());
    assert(layouts.len() == 1);
    assert(layout_fields.len() == 64);
    assert(layouts[0].size_bytes == 512);
    free_checker();
    declaration.append(", f64:i64");
    expect_layout_error(declaration.str_view(), 1, "STRUCT",
        "layout must contain 1..64 fields");
}

fn void layout_resource_capacities() @test {
    prepare_checker("");
    for (int i = 0; i < LAYOUT_MAX; i++) layouts.push({});
    op_layout("Unique: value:i64", 1);
    check_capacity_diagnostic("too many layouts");
    assert(layouts.len() == LAYOUT_MAX);
    free_checker();
    prepare_checker("");
    for (int i = 0; i < LAYOUT_FIELDS_TOTAL_MAX; i++) layout_fields.push({});
    op_layout("Unique: value:i64", 1);
    check_capacity_diagnostic("too many layout fields");
    assert(layout_fields.len() == LAYOUT_FIELDS_TOTAL_MAX);
    assert(layouts.len() == 0);
    free_checker();
}

fn void layout_dead_frame_res_is_atomic() @test {
    start_invalid_layout("cav gone, field\nlayout Entry: key:i64\n"
        "res before, gone, Entry\ndecay gone\nres late, gone, Entry\n");
    assert(violations == 1);
    assert(lsp_diags.len() == 1);
    assert(lsp_diags[0].line == 5);
    assert(lsp_diags[0].rule == "I1");
    assert(lsp_diags[0].msg == "cell in dead frame late gone");
    assert(cells.len() == 1);
    assert(layouts.len() == 1);
    free_checker();
}

fn void layout_parser_declaration_cap() @test {
    DString source = dstring::temp();
    defer source.free();
    for (int i = 0; i < LAYOUT_MAX; i++) {
        source.appendf("layout L%d: value:i64\n", i);
    }
    prepare_checker(source.str_view());
    assert(layouts.len() == LAYOUT_MAX);
    free_checker();
    source.append("layout L256: value:i64\n");
    start_invalid_layout(source.str_view());
    assert(violations == 1);
    assert(lsp_diags[0].line == LAYOUT_MAX + 1);
    assert(lsp_diags[0].msg == "too many layouts");
    assert(layouts.len() == LAYOUT_MAX);
    free_checker();
}

fn void layout_parser_total_field_cap() @test {
    DString source = dstring::temp();
    defer source.free();
    for (int i = 0; i < LAYOUT_MAX; i++) {
        source.appendf("layout L%d: f0:i64", i);
        for (int field = 1; field < LAYOUT_FIELDS_PER_MAX; field++) {
            source.appendf(", f%d:i64", field);
        }
        source.append("\n");
    }
    prepare_checker(source.str_view());
    assert(layouts.len() == LAYOUT_MAX);
    assert(layout_fields.len() == LAYOUT_FIELDS_TOTAL_MAX);
    free_checker();
}

fn void layout_empty_input_diagnostics() @test {
    expect_layout_error("layout Empty:\n", 1, "STRUCT", "empty layout field");
    expect_layout_error("layout Entry: key:i64\nres x, field, Entry[]\n",
        2, "STRUCT", "empty layout element count");
}
