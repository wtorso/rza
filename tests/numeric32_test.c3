module rez3asm;

fn void numeric32_typed_surface_is_closed() @test {
    assert(find_scalar_type("i32") ?? ScalarType.NONE == ScalarType.I32);
    assert(find_scalar_type("u32") ?? ScalarType.NONE == ScalarType.U32);
    TypeDesc* signed_word = scalar_type_desc(ScalarType.I32);
    TypeDesc* unsigned_word = scalar_type_desc(ScalarType.U32);
    assert(signed_word != null && signed_word.bit_width == 32);
    assert(signed_word.alignment_bytes == 4 && signed_word.typed_syntax);
    assert(signed_word.signedness == Signedness.SIGNED);
    assert(unsigned_word != null && unsigned_word.bit_width == 32);
    assert(unsigned_word.alignment_bytes == 4 && unsigned_word.typed_syntax);
    assert(unsigned_word.signedness == Signedness.UNSIGNED);
    assert(scalar_type_desc(ScalarType.I64).typed_syntax);
    assert(find_scalar_type("i64") ?? ScalarType.NONE == ScalarType.I64);
    assert(find_scalar_type("u64") ?? ScalarType.NONE == ScalarType.U64);
    assert(!@ok(find_scalar_type("f32")));
    OpDesc desc;
    assert(resolve_op_desc("mov.i32", &desc));
    assert(desc.op == Op.MOV && desc.scalar_type == ScalarType.I32);
    assert(resolve_op_desc("load.u32", &desc));
    assert(desc.op == Op.LOAD && desc.scalar_type == ScalarType.U32 && !desc.write);
    assert(resolve_op_desc("store.i32", &desc));
    assert(desc.op == Op.STORE && desc.scalar_type == ScalarType.I32 && desc.write);
    assert(!resolve_op_desc("mov.f32", &desc));
    assert(!resolve_op_desc("load.f32", &desc));
    assert(!resolve_op_desc("loadb.u32", &desc));
}

fn void numeric32_typed_literals_cover_boundaries() @test {
    Immediate value;
    assert(parse_typed_immediate("-2147483648", ScalarType.I32, 1, &value));
    assert(value.bits == 0x80000000 && value.literal_kind == LiteralKind.DECIMAL);
    assert(value.has_negative_sign);
    assert(parse_typed_immediate("2147483647", ScalarType.I32, 1, &value));
    assert(value.bits == 0x7fffffff && !value.has_negative_sign);
    assert(parse_typed_immediate("0x80000000", ScalarType.I32, 1, &value));
    assert(value.bits == 0x80000000 && value.literal_kind == LiteralKind.HEX_BITS);
    assert(parse_typed_immediate("0xffffffff", ScalarType.I32, 1, &value));
    assert(value.bits == 0xffffffff && !value.has_negative_sign);
    assert(parse_typed_immediate("0x000ffffffff", ScalarType.U32, 1, &value));
    assert(value.bits == 0xffffffff && value.literal_kind == LiteralKind.HEX_BITS);
    assert(parse_typed_immediate("4294967295", ScalarType.U32, 1, &value));
    assert(value.bits == 0xffffffff && value.literal_kind == LiteralKind.DECIMAL);
    assert(parse_typed_immediate("0Xffffffff", ScalarType.U32, 1, &value));
    assert(value.bits == 0xffffffff && value.literal_kind == LiteralKind.HEX_BITS);
    assert(parse_typed_immediate("-0", ScalarType.I32, 1, &value));
    assert(value.bits == 0 && value.has_negative_sign);
}

fn void numeric32_literal_error(String text, ScalarType type, String message) {
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

fn void numeric32_literal_diagnostics() @test {
    numeric32_literal_error("2147483648", ScalarType.I32,
        "immediate out of i32 range: 2147483648");
    numeric32_literal_error("-2147483649", ScalarType.I32,
        "immediate out of i32 range: -2147483649");
    numeric32_literal_error("0x100000000", ScalarType.I32,
        "immediate out of i32 range: 0x100000000");
    numeric32_literal_error("-0x1", ScalarType.I32,
        "immediate out of i32 range: -0x1");
    numeric32_literal_error("-1", ScalarType.U32, "immediate out of u32 range: -1");
    numeric32_literal_error("4294967296", ScalarType.U32,
        "immediate out of u32 range: 4294967296");
    numeric32_literal_error("0x100000000", ScalarType.U32,
        "immediate out of u32 range: 0x100000000");
}

fn void numeric32_unsigned_negative_zero_is_rejected() @test {
    numeric32_literal_error("-0", ScalarType.U32, "immediate out of u32 range: -0");
    numeric32_literal_error("-00", ScalarType.U32, "immediate out of u32 range: -00");
    start_invalid_layout("mov.u32 %r0, -0\n");
    assert(violations == 1 && lsp_diags.len() == 1);
    assert(lsp_diags[0].msg == "immediate out of u32 range: -0");
    assert(instrs.len() == 0);
    free_checker();
}

fn void numeric32_instruction_types_reach_checker() @test {
    prepare_checker("layout Pair: tag:u8, word:i32, guard:u16, tail:u32\n"
        "res pair, field, Pair\nmed pair_m, pair, field\nmov.i32 %r0, 0xffffffff\n"
        "load.i32 %r1, [pair_m + 0].word\nstore.i32 [pair_m + 0].word, %r1\n");
    assert(layouts[0].size_bytes == 16 && layouts[0].alignment_bytes == 4);
    assert(layout_fields[0].offset_bytes == 0 && layout_fields[0].scalar_type == ScalarType.U8);
    assert(layout_fields[1].offset_bytes == 4 && layout_fields[1].scalar_type == ScalarType.I32);
    assert(layout_fields[2].offset_bytes == 8 && layout_fields[2].scalar_type == ScalarType.U16);
    assert(layout_fields[3].offset_bytes == 12 && layout_fields[3].scalar_type == ScalarType.U32);
    assert(instrs.len() == 5);
    assert(instrs[2].scalar_type == ScalarType.I32);
    assert(instrs[2].immediate.bits == 0xffffffff);
    assert(instrs[3].scalar_type == ScalarType.I32);
    assert(instrs[4].scalar_type == ScalarType.I32);
    free_checker();
}

fn void numeric32_lsp_uses_typed_memory_context() @test {
    assert(memory_completion_context("load.i32", 1) == CompletionContext.MED);
    assert(memory_completion_context("load.u32", 1) == CompletionContext.MED);
    assert(memory_completion_context("store.i32", 0) == CompletionContext.MED);
    assert(memory_completion_context("store.u32", 0) == CompletionContext.MED);
    assert(memory_completion_context("load.i64", 1) == CompletionContext.MED);
    assert(memory_completion_context("load.f32", 1) == CompletionContext.NONE);
}

fn void numeric32_layout_metrics_use_descriptor_alignment() @test {
    TypeDesc desc = { .bit_width = 32, .alignment_bytes = 4 };
    int width = 0;
    int alignment = 0;
    type_layout_metrics(&desc, &width, &alignment);
    assert(width == 4 && alignment == 4);
}

fn void numeric32_wrap_and_compare_resolve_by_type() @test {
    String[] names = {
        "add.i32", "add.u32", "sub.i32", "sub.u32", "mul.i32", "mul.u32",
        "inc.i32", "inc.u32", "dec.i32", "dec.u32",
        "and.i32", "and.u32", "or.i32", "or.u32", "xor.i32", "xor.u32",
        "slt.i32", "ult.u32"
    };
    foreach (name : names) {
        OpDesc desc;
        assert(resolve_op_desc(name, &desc));
        assert(desc.typed && desc.cascade_ok);
    }
    OpDesc desc;
    assert(!resolve_op_desc("ult", &desc));
    assert(!resolve_op_desc("shr.u32", &desc));
    assert(!resolve_op_desc("slt.u32", &desc));
    assert(!resolve_op_desc("ult.i32", &desc));
    assert(!resolve_op_desc("add.f32", &desc));
    assert(resolve_op_desc("ult.u32", &desc));
    assert(desc.alu_op == AluOp.ULT && desc.scalar_type == ScalarType.U32);
}

fn void numeric32_reject_in_context(String token, int context) {
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

fn void numeric32_malformed_ops_fail_closed_in_every_context() @test {
    String[] tokens = {
        "shr.u32", "slt.u32", "ult.i32", "ult", "load.f32", "mov.f32",
        "loadb.u32", "crc32c.i32", "print.i32", "cvt.i32", "bitcast.u32",
        "add.f32", "add..i32", "add.i32.more",
    };
    foreach (token : tokens) {
        for (int context = 0; context < 4; context++) {
            numeric32_reject_in_context(token, context);
        }
    }
}
