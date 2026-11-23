module rez3asm;

fn void numeric8_typed_surface_is_closed() @test {
    assert(find_scalar_type("i8") ?? ScalarType.NONE == ScalarType.I8);
    TypeDesc* signed_byte = scalar_type_desc(ScalarType.I8);
    assert(signed_byte != null && signed_byte.bit_width == 8);
    assert(signed_byte.alignment_bytes == 1);
    assert(signed_byte.signedness == Signedness.SIGNED && signed_byte.typed_syntax);
    assert(scalar_type_desc(ScalarType.U8).typed_syntax);
    assert(scalar_type_desc(ScalarType.I64).typed_syntax);
    assert(find_scalar_type("i32") ?? ScalarType.NONE == ScalarType.I32);
    assert(find_scalar_type("u64") ?? ScalarType.NONE == ScalarType.U64);
    assert(find_scalar_type("f32") ?? ScalarType.NONE == ScalarType.F32);
    OpDesc desc;
    assert(resolve_op_desc("mov.i8", &desc));
    assert(desc.op == Op.MOV && desc.scalar_type == ScalarType.I8);
    assert(resolve_op_desc("load.u8", &desc));
    assert(desc.op == Op.LOAD && desc.scalar_type == ScalarType.U8 && !desc.write);
    assert(resolve_op_desc("store.i8", &desc));
    assert(desc.op == Op.STORE && desc.scalar_type == ScalarType.I8 && desc.write);
    assert(resolve_op_desc("mov.f32", &desc));
    assert(desc.op == Op.MOV && desc.scalar_type == ScalarType.F32);
    assert(resolve_op_desc("load.f32", &desc));
    assert(desc.op == Op.LOAD && desc.scalar_type == ScalarType.F32);
    assert(!resolve_op_desc("loadb.u8", &desc));
    assert(resolve_op_desc("add.i8", &desc));
    assert(!resolve_op_desc("shr.u8", &desc));
    assert(!resolve_op_desc("ult", &desc));
}

fn void numeric8_typed_literals_cover_boundaries() @test {
    Immediate value;
    assert(parse_typed_immediate("-128", ScalarType.I8, 1, &value));
    assert(value.bits == 0x80 && value.literal_kind == LiteralKind.DECIMAL);
    assert(value.has_negative_sign);
    assert(parse_typed_immediate("127", ScalarType.I8, 1, &value));
    assert(value.bits == 0x7f && !value.has_negative_sign);
    assert(parse_typed_immediate("0x000ff", ScalarType.I8, 1, &value));
    assert(value.bits == 0xff && value.literal_kind == LiteralKind.HEX_BITS);
    assert(!value.has_negative_sign);
    assert(parse_typed_immediate("255", ScalarType.U8, 1, &value));
    assert(value.bits == 0xff && value.literal_kind == LiteralKind.DECIMAL);
    assert(parse_typed_immediate("0Xff", ScalarType.U8, 1, &value));
    assert(value.bits == 0xff && value.literal_kind == LiteralKind.HEX_BITS);
    assert(parse_typed_immediate("-0", ScalarType.I8, 1, &value));
    assert(value.bits == 0 && value.has_negative_sign);
}

fn void numeric8_literal_error(String text, ScalarType type, String message) {
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

fn void numeric8_literal_diagnostics() @test {
    numeric8_literal_error("128", ScalarType.I8, "immediate out of i8 range: 128");
    numeric8_literal_error("-129", ScalarType.I8, "immediate out of i8 range: -129");
    numeric8_literal_error("0x100", ScalarType.I8, "immediate out of i8 range: 0x100");
    numeric8_literal_error("-0x1", ScalarType.I8, "immediate out of i8 range: -0x1");
    numeric8_literal_error("-1", ScalarType.U8, "immediate out of u8 range: -1");
    numeric8_literal_error("256", ScalarType.U8, "immediate out of u8 range: 256");
    numeric8_literal_error("0x100", ScalarType.U8, "immediate out of u8 range: 0x100");
}

fn void numeric8_unsigned_negative_zero_is_rejected() @test {
    numeric8_literal_error("-0", ScalarType.U8, "immediate out of u8 range: -0");
    numeric8_literal_error("-00", ScalarType.U8, "immediate out of u8 range: -00");
    start_invalid_layout("mov.u8 %r0, -0\n");
    assert(violations == 1 && lsp_diags.len() == 1);
    assert(lsp_diags[0].msg == "immediate out of u8 range: -0");
    assert(instrs.len() == 0);
    free_checker();
}

fn void numeric8_instruction_types_reach_checker() @test {
    prepare_checker("layout Pair: left:i8, right:u8\nres pair, field, Pair\n"
        "med pair_m, pair, field\nmov.i8 %r0, 0xff\n"
        "load.i8 %r1, [pair_m + 0].left\nstore.u8 [pair_m + 0].right, %r1\n");
    assert(instrs.len() == 5);
    assert(instrs[2].scalar_type == ScalarType.I8);
    assert(instrs[2].immediate.bits == 0xff);
    assert(instrs[3].scalar_type == ScalarType.I8);
    assert(instrs[4].scalar_type == ScalarType.U8);
    free_checker();
}

fn void numeric8_lsp_uses_typed_memory_context() @test {
    assert(memory_completion_context("load.i8", 1) == CompletionContext.MED);
    assert(memory_completion_context("load.u8", 1) == CompletionContext.MED);
    assert(memory_completion_context("store.i8", 0) == CompletionContext.MED);
    assert(memory_completion_context("store.u8", 0) == CompletionContext.MED);
    assert(memory_completion_context("load.i64", 1) == CompletionContext.MED);
    assert(memory_completion_context("load.f32", 1) == CompletionContext.MED);
}

fn void numeric8_wrap_and_compare_resolve_by_type() @test {
    String[] names = {
        "add.i8", "add.u8", "sub.i8", "sub.u8", "mul.i8", "mul.u8",
        "inc.i8", "inc.u8", "dec.i8", "dec.u8",
        "and.i8", "and.u8", "or.i8", "or.u8", "xor.i8", "xor.u8",
        "slt.i8", "ult.u8"
    };
    foreach (name : names) {
        OpDesc desc;
        assert(resolve_op_desc(name, &desc));
        assert(desc.typed && desc.cascade_ok);
    }
    OpDesc desc;
    assert(!resolve_op_desc("ult", &desc));
    assert(!resolve_op_desc("slt.u8", &desc));
    assert(!resolve_op_desc("ult.i8", &desc));
    assert(resolve_op_desc("add.f32", &desc));
    assert(desc.alu_op == AluOp.ADD && desc.scalar_type == ScalarType.F32);
    assert(resolve_op_desc("ult.u8", &desc));
    assert(desc.alu_op == AluOp.ULT && desc.scalar_type == ScalarType.U8);
}

fn void numeric8_fault_operations_complete_the_surface() @test {
    String[] names = {
        "cadd.i8", "cadd.u8", "csub.i8", "csub.u8", "cmul.i8", "cmul.u8",
        "cinc.i8", "cinc.u8", "cdec.i8", "cdec.u8",
        "div.i8", "div.u8", "mod.i8", "mod.u8",
        "shl.i8", "shl.u8", "shr.i8", "ushr.i8", "ushr.u8"
    };
    foreach (name : names) {
        OpDesc desc;
        assert(resolve_op_desc(name, &desc));
        assert(desc.typed && desc.cascade_ok);
    }
    OpDesc desc;
    assert(!resolve_op_desc("shr.u8", &desc));
    assert(!resolve_op_desc("slt.u8", &desc));
    assert(!resolve_op_desc("ult.i8", &desc));
    assert(!resolve_op_desc("cadd.f32", &desc));
    assert(!resolve_op_desc("crc32c.i8", &desc));
    assert(resolve_op_desc("div.f32", &desc));
    assert(desc.alu_op == AluOp.DIV && desc.scalar_type == ScalarType.F32);
    assert(!resolve_op_desc("mod.f32", &desc));
    prepare_checker("shl.i8 %r2, %r0, -1\nushr.u8 %r3, %r0, 8\n");
    assert(instrs.len() == 2);
    assert(instrs[0].immediate.bits == ulong::max);
    assert(instrs[0].immediate.literal_kind == LiteralKind.DECIMAL);
    assert(instrs[0].immediate.has_negative_sign);
    assert(instrs[1].immediate.bits == 8);
    free_checker();
}

fn void numeric8_reject_in_context(String token, int context) {
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

fn void numeric8_malformed_ops_fail_closed_in_every_context() @test {
    String[] tokens = {
        "shr.u8", "load.f16", "ult", "loadb.u8", "add..i8", "add.i8.more",
    };
    foreach (token : tokens) {
        for (int context = 0; context < 4; context++) {
            numeric8_reject_in_context(token, context);
        }
    }
}
