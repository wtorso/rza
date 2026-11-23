module rez3asm;

fn void numeric16_typed_surface_is_closed() @test {
    assert(find_scalar_type("i16") ?? ScalarType.NONE == ScalarType.I16);
    assert(find_scalar_type("u16") ?? ScalarType.NONE == ScalarType.U16);
    TypeDesc* signed_half = scalar_type_desc(ScalarType.I16);
    TypeDesc* unsigned_half = scalar_type_desc(ScalarType.U16);
    assert(signed_half != null && signed_half.bit_width == 16);
    assert(signed_half.alignment_bytes == 2 && signed_half.typed_syntax);
    assert(signed_half.signedness == Signedness.SIGNED);
    assert(unsigned_half != null && unsigned_half.signedness == Signedness.UNSIGNED);
    assert(unsigned_half.typed_syntax);
    assert(scalar_type_desc(ScalarType.I64).typed_syntax);
    assert(find_scalar_type("i32") ?? ScalarType.NONE == ScalarType.I32);
    assert(find_scalar_type("u64") ?? ScalarType.NONE == ScalarType.U64);
    assert(find_scalar_type("f32") ?? ScalarType.NONE == ScalarType.F32);
    OpDesc desc;
    assert(resolve_op_desc("mov.i16", &desc));
    assert(desc.op == Op.MOV && desc.scalar_type == ScalarType.I16);
    assert(resolve_op_desc("load.u16", &desc));
    assert(desc.op == Op.LOAD && desc.scalar_type == ScalarType.U16 && !desc.write);
    assert(resolve_op_desc("store.i16", &desc));
    assert(desc.op == Op.STORE && desc.scalar_type == ScalarType.I16 && desc.write);
    assert(resolve_op_desc("mov.f32", &desc));
    assert(desc.op == Op.MOV && desc.scalar_type == ScalarType.F32);
    assert(resolve_op_desc("load.f32", &desc));
    assert(desc.op == Op.LOAD && desc.scalar_type == ScalarType.F32);
    assert(!resolve_op_desc("loadb.u16", &desc));
}

fn void numeric16_typed_literals_cover_boundaries() @test {
    Immediate value;
    assert(parse_typed_immediate("-32768", ScalarType.I16, 1, &value));
    assert(value.bits == 0x8000 && value.literal_kind == LiteralKind.DECIMAL);
    assert(value.has_negative_sign);
    assert(parse_typed_immediate("32767", ScalarType.I16, 1, &value));
    assert(value.bits == 0x7fff && !value.has_negative_sign);
    assert(parse_typed_immediate("0x000ffff", ScalarType.I16, 1, &value));
    assert(value.bits == 0xffff && value.literal_kind == LiteralKind.HEX_BITS);
    assert(!value.has_negative_sign);
    assert(parse_typed_immediate("65535", ScalarType.U16, 1, &value));
    assert(value.bits == 0xffff && value.literal_kind == LiteralKind.DECIMAL);
    assert(parse_typed_immediate("0Xffff", ScalarType.U16, 1, &value));
    assert(value.bits == 0xffff && value.literal_kind == LiteralKind.HEX_BITS);
    assert(parse_typed_immediate("-0", ScalarType.I16, 1, &value));
    assert(value.bits == 0 && value.has_negative_sign);
}

fn void numeric16_literal_error(String text, ScalarType type, String message) {
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

fn void numeric16_literal_diagnostics() @test {
    numeric16_literal_error("32768", ScalarType.I16, "immediate out of i16 range: 32768");
    numeric16_literal_error("-32769", ScalarType.I16, "immediate out of i16 range: -32769");
    numeric16_literal_error("0x10000", ScalarType.I16, "immediate out of i16 range: 0x10000");
    numeric16_literal_error("-0x1", ScalarType.I16, "immediate out of i16 range: -0x1");
    numeric16_literal_error("-1", ScalarType.U16, "immediate out of u16 range: -1");
    numeric16_literal_error("65536", ScalarType.U16, "immediate out of u16 range: 65536");
    numeric16_literal_error("0x10000", ScalarType.U16, "immediate out of u16 range: 0x10000");
}

fn void numeric16_unsigned_negative_zero_is_rejected() @test {
    numeric16_literal_error("-0", ScalarType.U16, "immediate out of u16 range: -0");
    numeric16_literal_error("-00", ScalarType.U16, "immediate out of u16 range: -00");
    start_invalid_layout("mov.u16 %r0, -0\n");
    assert(violations == 1 && lsp_diags.len() == 1);
    assert(lsp_diags[0].msg == "immediate out of u16 range: -0");
    assert(instrs.len() == 0);
    free_checker();
}

fn void numeric16_instruction_types_reach_checker() @test {
    prepare_checker("layout Pair: tag:u8, half:i16, word:i64\n"
        "res pair, field, Pair\nmed pair_m, pair, field\nmov.i16 %r0, 0xffff\n"
        "load.i16 %r1, [pair_m + 0].half\nstore.i16 [pair_m + 0].half, %r1\n");
    assert(layouts[0].size_bytes == 16 && layouts[0].alignment_bytes == 8);
    assert(layout_fields[0].offset_bytes == 0 && layout_fields[0].scalar_type == ScalarType.U8);
    assert(layout_fields[1].offset_bytes == 2 && layout_fields[1].scalar_type == ScalarType.I16);
    assert(layout_fields[2].offset_bytes == 8 && layout_fields[2].scalar_type == ScalarType.I64);
    assert(instrs.len() == 5);
    assert(instrs[2].scalar_type == ScalarType.I16 && instrs[2].immediate.bits == 0xffff);
    assert(instrs[3].scalar_type == ScalarType.I16);
    assert(instrs[4].scalar_type == ScalarType.I16);
    free_checker();
}

fn void numeric16_lsp_uses_typed_memory_context() @test {
    assert(memory_completion_context("load.i16", 1) == CompletionContext.MED);
    assert(memory_completion_context("load.u16", 1) == CompletionContext.MED);
    assert(memory_completion_context("store.i16", 0) == CompletionContext.MED);
    assert(memory_completion_context("store.u16", 0) == CompletionContext.MED);
    assert(memory_completion_context("load.i64", 1) == CompletionContext.MED);
    assert(memory_completion_context("load.f32", 1) == CompletionContext.MED);
}

fn void numeric16_wrap_and_compare_resolve_by_type() @test {
    String[] names = {
        "add.i16", "add.u16", "sub.i16", "sub.u16", "mul.i16", "mul.u16",
        "inc.i16", "inc.u16", "dec.i16", "dec.u16",
        "and.i16", "and.u16", "or.i16", "or.u16", "xor.i16", "xor.u16",
        "slt.i16", "ult.u16"
    };
    foreach (name : names) {
        OpDesc desc;
        assert(resolve_op_desc(name, &desc));
        assert(desc.typed && desc.cascade_ok);
    }
    OpDesc desc;
    assert(!resolve_op_desc("ult", &desc));
    assert(!resolve_op_desc("shr.u16", &desc));
    assert(!resolve_op_desc("slt.u16", &desc));
    assert(!resolve_op_desc("ult.i16", &desc));
    assert(resolve_op_desc("add.f32", &desc));
    assert(desc.alu_op == AluOp.ADD && desc.scalar_type == ScalarType.F32);
    assert(resolve_op_desc("ult.u16", &desc));
    assert(desc.alu_op == AluOp.ULT && desc.scalar_type == ScalarType.U16);
}

fn void numeric16_layout_metrics_use_descriptor_alignment() @test {
    TypeDesc desc = { .bit_width = 16, .alignment_bytes = 2 };
    int width = 0;
    int alignment = 0;
    type_layout_metrics(&desc, &width, &alignment);
    assert(width == 2 && alignment == 2);
}

fn void numeric16_reject_in_context(String token, int context) {
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

fn void numeric16_malformed_ops_fail_closed_in_every_context() @test {
    String[] tokens = {
        "shr.u16", "slt.u16", "ult.i16", "ult", "load.f16", "mov.bf16",
        "loadb.u16", "add..i16", "add.i16.more",
    };
    foreach (token : tokens) {
        for (int context = 0; context < 4; context++) {
            numeric16_reject_in_context(token, context);
        }
    }
}
