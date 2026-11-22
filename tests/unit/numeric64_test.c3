module rez3asm;

fn void numeric64_typed_surface_is_closed() @test {
    assert(find_scalar_type("i64") ?? ScalarType.NONE == ScalarType.I64);
    assert(find_scalar_type("u64") ?? ScalarType.NONE == ScalarType.U64);
    TypeDesc* signed_word = scalar_type_desc(ScalarType.I64);
    TypeDesc* unsigned_word = scalar_type_desc(ScalarType.U64);
    assert(signed_word != null && signed_word.bit_width == 64);
    assert(signed_word.alignment_bytes == 8 && signed_word.typed_syntax);
    assert(signed_word.signedness == Signedness.SIGNED);
    assert(unsigned_word != null && unsigned_word.bit_width == 64);
    assert(unsigned_word.alignment_bytes == 8 && unsigned_word.typed_syntax);
    assert(unsigned_word.signedness == Signedness.UNSIGNED);
    assert(!@ok(find_scalar_type("f32")));
    OpDesc desc;
    assert(resolve_op_desc("mov.i64", &desc));
    assert(desc.op == Op.MOV && desc.scalar_type == ScalarType.I64);
    assert(resolve_op_desc("load.u64", &desc));
    assert(desc.op == Op.LOAD && desc.scalar_type == ScalarType.U64 && !desc.write);
    assert(resolve_op_desc("store.i64", &desc));
    assert(desc.op == Op.STORE && desc.scalar_type == ScalarType.I64 && desc.write);
    assert(!resolve_op_desc("mov.f32", &desc));
    assert(!resolve_op_desc("loadb.u64", &desc));
}

fn void numeric64_typed_literals_cover_boundaries() @test {
    Immediate value;
    assert(parse_typed_immediate("-9223372036854775808", ScalarType.I64, 1, &value));
    assert(value.bits == 0x8000000000000000 && value.literal_kind == LiteralKind.DECIMAL);
    assert(value.has_negative_sign);
    assert(parse_typed_immediate("9223372036854775807", ScalarType.I64, 1, &value));
    assert(value.bits == 0x7fffffffffffffff && !value.has_negative_sign);
    assert(parse_typed_immediate("0x8000000000000000", ScalarType.I64, 1, &value));
    assert(value.bits == 0x8000000000000000 && value.literal_kind == LiteralKind.HEX_BITS);
    assert(parse_typed_immediate("0xffffffffffffffff", ScalarType.I64, 1, &value));
    assert(value.bits == ulong::max && !value.has_negative_sign);
    assert(parse_typed_immediate("-0x1", ScalarType.I64, 1, &value));
    assert(value.bits == ulong::max && value.literal_kind == LiteralKind.HEX_BITS);
    assert(value.has_negative_sign);
    assert(parse_typed_immediate("-0", ScalarType.I64, 1, &value));
    assert(value.bits == 0 && value.has_negative_sign);
    assert(parse_typed_immediate("18446744073709551615", ScalarType.U64, 1, &value));
    assert(value.bits == ulong::max && value.literal_kind == LiteralKind.DECIMAL);
    assert(!value.has_negative_sign);
    assert(parse_typed_immediate("0x000ffffffffffffffff", ScalarType.U64, 1, &value));
    assert(value.bits == ulong::max && value.literal_kind == LiteralKind.HEX_BITS);
    assert(!value.has_negative_sign);
    assert(parse_typed_immediate("0", ScalarType.U64, 1, &value));
    assert(value.bits == 0 && !value.has_negative_sign);
}

fn void numeric64_literal_error(String text, ScalarType type, String message) {
    init_workmem();
    reset_state();
    list_guard.freeze();
    g_lsp_mode = true;
    Immediate value;
    assert(!parse_typed_immediate(text, type, 1, &value));
    assert(violations == 1 && lsp_diags.len() == 1);
    assert(lsp_diags[0].line == 1 && lsp_diags[0].rule == "STRUCT");
    assert(lsp_diags[0].msg == message);
    free_checker();
}

fn void numeric64_literal_diagnostics() @test {
    numeric64_literal_error("9223372036854775808", ScalarType.I64,
        "immediate out of i64 range: 9223372036854775808");
    numeric64_literal_error("-9223372036854775809", ScalarType.I64,
        "immediate out of i64 range: -9223372036854775809");
    numeric64_literal_error("0x10000000000000000", ScalarType.I64,
        "immediate out of i64 range: 0x10000000000000000");
    numeric64_literal_error("-1", ScalarType.U64, "immediate out of u64 range: -1");
    numeric64_literal_error("-0x1", ScalarType.U64, "immediate out of u64 range: -0x1");
    numeric64_literal_error("18446744073709551616", ScalarType.U64,
        "immediate out of u64 range: 18446744073709551616");
    numeric64_literal_error("0x10000000000000000", ScalarType.U64,
        "immediate out of u64 range: 0x10000000000000000");
}

fn void numeric64_unsigned_negative_zero_is_rejected() @test {
    numeric64_literal_error("-0", ScalarType.U64, "immediate out of u64 range: -0");
    numeric64_literal_error("-00", ScalarType.U64, "immediate out of u64 range: -00");
    start_invalid_layout("mov.u64 %r0, -0\n");
    assert(violations == 1 && lsp_diags.len() == 1);
    assert(lsp_diags[0].msg == "immediate out of u64 range: -0");
    assert(instrs.len() == 0);
    free_checker();
}

fn void numeric64_instruction_types_reach_checker() @test {
    prepare_checker("layout Pair: tag:u8, word:i64, guard:u16, tail:u64\n"
        "res pair, field, Pair\nmed pair_m, pair, field\nmov.i64 %r0, -0x1\n"
        "load.i64 %r1, [pair_m + 0].word\nstore.i64 [pair_m + 0].word, %r1\n");
    assert(layouts[0].size_bytes == 32 && layouts[0].alignment_bytes == 8);
    assert(layout_fields[0].offset_bytes == 0 && layout_fields[0].scalar_type == ScalarType.U8);
    assert(layout_fields[1].offset_bytes == 8 && layout_fields[1].scalar_type == ScalarType.I64);
    assert(layout_fields[2].offset_bytes == 16 && layout_fields[2].scalar_type == ScalarType.U16);
    assert(layout_fields[3].offset_bytes == 24 && layout_fields[3].scalar_type == ScalarType.U64);
    assert(instrs.len() == 5);
    assert(instrs[2].scalar_type == ScalarType.I64);
    assert(instrs[2].immediate.bits == ulong::max);
    assert(instrs[2].immediate.literal_kind == LiteralKind.HEX_BITS);
    assert(instrs[2].immediate.has_negative_sign);
    assert(instrs[3].scalar_type == ScalarType.I64);
    assert(instrs[4].scalar_type == ScalarType.I64);
    free_checker();
}

fn void numeric64_lsp_uses_typed_memory_context() @test {
    assert(memory_completion_context("load.i64", 1) == CompletionContext.MED);
    assert(memory_completion_context("load.u64", 1) == CompletionContext.MED);
    assert(memory_completion_context("store.i64", 0) == CompletionContext.MED);
    assert(memory_completion_context("store.u64", 0) == CompletionContext.MED);
    assert(memory_completion_context("load.f32", 1) == CompletionContext.NONE);
}

fn void numeric64_layout_metrics_use_descriptor_alignment() @test {
    TypeDesc desc = { .bit_width = 64, .alignment_bytes = 8 };
    int width = 0;
    int alignment = 0;
    type_layout_metrics(&desc, &width, &alignment);
    assert(width == 8 && alignment == 8);
}

fn void numeric64_wrap_and_compare_resolve_by_type() @test {
    String[] names = {
        "add.i64", "add.u64", "sub.i64", "sub.u64", "mul.i64", "mul.u64",
        "inc.i64", "inc.u64", "dec.i64", "dec.u64",
        "and.i64", "and.u64", "or.i64", "or.u64", "xor.i64", "xor.u64",
        "slt.i64", "ult.u64"
    };
    foreach (name : names) {
        OpDesc desc;
        assert(resolve_op_desc(name, &desc));
        assert(desc.typed && desc.cascade_ok);
    }
    OpDesc desc;
    assert(!resolve_op_desc("ult", &desc));
    assert(!resolve_op_desc("shr.u64", &desc));
    assert(!resolve_op_desc("slt.u64", &desc));
    assert(!resolve_op_desc("ult.i64", &desc));
    assert(!resolve_op_desc("add.f32", &desc));
    assert(resolve_op_desc("ult.u64", &desc));
    assert(desc.alu_op == AluOp.ULT && desc.scalar_type == ScalarType.U64);
}

fn void numeric64_reject_in_context(String token, int context) {
    init_workmem();
    reset_state();
    list_guard.freeze();
    g_lsp_mode = true;
    String source;
    int line = 1;
    switch (context) {
        case 0:
            source = cat({ token, "\n" });
        case 1:
            source = cat({ "proc worker:\n    ", token, "\n    ret\n" });
            line = 2;
        case 2:
            source = cat({ "res raw, field, 8\nmed raw_m, raw, field\n",
                "casc c: raw_m -> out[field]\n", token, "\nendc\nret\n" });
            line = 4;
        case 3:
            source = cat({ "res raw, field, 8\nmed raw_m, raw, field\n",
                "acasc c: raw_m -> out\n", token, "\nendc\nawait %r0\nret\n" });
            line = 4;
        default:
            unreachable();
    }
    run(source);
    String message = context < 2 ? cat({ "unknown op ", token }) : cat({
        "op ", token, context == 2
            ? " not allowed in cascade body (data instructions only)"
            : " not allowed in async cascade body (data instructions only)"
    });
    assert(violations == 1 && lsp_diags.len() == 1);
    assert(lsp_diags[0].line == line && lsp_diags[0].rule == "STRUCT");
    assert(lsp_diags[0].msg == message);
    foreach (ins : instrs) assert(ins.line != line);
    free_checker();
}

fn void numeric64_malformed_ops_fail_closed_in_every_context() @test {
    String[] tokens = {
        "shr.u64", "slt.u64", "ult.i64", "ult", "load.f32", "mov.f32",
        "loadb.u64", "crc32c.i64", "print.i64", "cvt.i64", "bitcast.u64",
        "add.f32", "add..i64", "add.i64.more",
    };
    foreach (token : tokens) {
        for (int context = 0; context < 4; context++) {
            numeric64_reject_in_context(token, context);
        }
    }
}
