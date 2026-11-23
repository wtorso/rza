module rez3asm;

fn void float_type_descriptors_are_ieee_binary() @test {
    TypeDesc* single = scalar_type_desc(ScalarType.F32);
    TypeDesc* word = scalar_type_desc(ScalarType.F64);
    assert(single != null && single.source_name == "f32");
    assert(single.bit_width == 32 && single.alignment_bytes == 4);
    assert(single.kind == TypeKind.IEEE_FLOAT);
    assert(single.signedness == Signedness.NONE);
    assert(single.conversion_class == ConversionClass.IEEE_BINARY);
    assert(single.typed_syntax && !single.storage_only);
    assert(word != null && word.source_name == "f64");
    assert(word.bit_width == 64 && word.alignment_bytes == 8);
    assert(word.kind == TypeKind.IEEE_FLOAT);
    assert(word.signedness == Signedness.NONE);
    assert(word.conversion_class == ConversionClass.IEEE_BINARY);
    assert(word.typed_syntax && !word.storage_only);
}

fn void float_storage_operations_resolve_with_shared_descriptors() @test {
    OpDesc desc;
    assert(resolve_op_desc("mov.f32", &desc));
    assert(desc.op == Op.MOV && desc.scalar_type == ScalarType.F32);
    assert(resolve_op_desc("load.f32", &desc));
    assert(desc.op == Op.LOAD && desc.scalar_type == ScalarType.F32 && !desc.write);
    assert(resolve_op_desc("store.f64", &desc));
    assert(desc.op == Op.STORE && desc.scalar_type == ScalarType.F64 && desc.write);
    assert(resolve_op_desc("add.f32", &desc));
    assert(desc.op == Op.ALU3 && desc.scalar_type == ScalarType.F32);
    assert(resolve_op_desc("feq.f64", &desc));
    assert(desc.op == Op.ALU3 && desc.alu_op == AluOp.FEQ);
    assert(resolve_op_desc("cvt.f32.f64", &desc));
    assert(desc.op == Op.CVT && desc.scalar_type == ScalarType.F32);
    assert(desc.source_type == ScalarType.F64);
    assert(resolve_op_desc("bitcast.u32.f32", &desc));
    assert(desc.op == Op.BITCAST && desc.scalar_type == ScalarType.U32);
    assert(desc.source_type == ScalarType.F32);
    assert(find_op_desc("cvt").op == Op.CVT);
    assert(find_op_desc("bitcast").op == Op.BITCAST);
    assert(memory_completion_context("load.f32", 1) == CompletionContext.MED);
}

fn void float_hex_literals_have_exact_width() @test {
    Immediate value;
    assert(parse_typed_immediate("0x3f800000", ScalarType.F32, 1, &value));
    assert(value.bits == 0x3f800000 && value.literal_kind == LiteralKind.HEX_BITS);
    assert(!value.has_negative_sign);
    assert(parse_typed_immediate("0XFFFFFFFF", ScalarType.F32, 1, &value));
    assert(value.bits == 0xffffffff && value.literal_kind == LiteralKind.HEX_BITS);
    assert(parse_typed_immediate("0x3ff0000000000000", ScalarType.F64, 1, &value));
    assert(value.bits == 0x3ff0000000000000);
    assert(value.literal_kind == LiteralKind.HEX_BITS);
    assert(parse_typed_immediate("0xffffffffffffffff", ScalarType.F64, 1, &value));
    assert(value.bits == ulong::max);
}

fn void float_reject_literal(String text, ScalarType type) {
    init_workmem();
    reset_state();
    list_guard.freeze();
    g_lsp_mode = true;
    Immediate value;
    assert(!parse_typed_immediate(text, type, 1, &value));
    assert(violations == 1 && lsp_diags.len() == 1);
    assert(lsp_diags[0].line == 1 && lsp_diags[0].rule == "STRUCT");
    assert(lsp_diags[0].msg == cat({"immediate out of ", type == ScalarType.F32
        ? "f32" : "f64", " range: ", text}));
    free_checker();
}

fn void float_literals_reject_sign_decimal_and_wrong_width() @test {
    String[] invalid32 = {
        "0x0", "0x000000000", "-0x00000000", "+0x00000000", "1", "1.0", "0xgg000000"
    };
    foreach (text : invalid32) float_reject_literal(text, ScalarType.F32);
    String[] invalid64 = {
        "0x00000000", "0x00000000000000000", "-0x0000000000000000", "1", "1.0"
    };
    foreach (text : invalid64) float_reject_literal(text, ScalarType.F64);
}

fn void float_layout_and_checker_use_exact_types() @test {
    prepare_checker("layout Pair: tag:u8, single:f32, guard:u16, word:f64, tail:f32\n"
        "res pair, field, Pair\nmed pair_m, pair, field\n"
        "mov.f32 %r0, 0x3f800000\nmov.f64 %r1, 0x3ff0000000000000\n"
        "load.f32 %r2, [pair_m + 0].single\nstore.f32 [pair_m + 0].tail, %r2\n"
        "load.f64 %r3, [pair_m + 0].word\nstore.f64 [pair_m + 0].word, %r3\n");
    assert(layouts[0].size_bytes == 32 && layouts[0].alignment_bytes == 8);
    assert(layout_fields[0].offset_bytes == 0);
    assert(layout_fields[1].offset_bytes == 4);
    assert(layout_fields[2].offset_bytes == 8);
    assert(layout_fields[3].offset_bytes == 16);
    assert(layout_fields[4].offset_bytes == 24);
    assert(instrs.len() == 8);
    assert(instrs[2].scalar_type == ScalarType.F32);
    assert(instrs[2].source_type == ScalarType.NONE);
    assert(instrs[3].scalar_type == ScalarType.F64);
    assert(instrs[3].source_type == ScalarType.NONE);
    assert(instrs[4].scalar_type == ScalarType.F32 && instrs[4].y == 1);
    assert(instrs[5].scalar_type == ScalarType.F32 && instrs[5].y == 4);
    assert(instrs[6].scalar_type == ScalarType.F64 && instrs[6].y == 3);
    assert(instrs[7].scalar_type == ScalarType.F64 && instrs[7].y == 3);
    free_checker();
}


fn void float_conversion_descriptors_resolve_as_a_closed_matrix() @test {
    assert(CONVERSION_DESCS.len == 42);
    for (usz i = 0; i < CONVERSION_DESCS.len; i++) {
        ConversionDesc desc = CONVERSION_DESCS[i];
        for (usz j = i + 1; j < CONVERSION_DESCS.len; j++) {
            assert(desc.source_name != CONVERSION_DESCS[j].source_name);
        }
        OpDesc resolved;
        assert(resolve_op_desc(desc.source_name, &resolved));
        assert(resolved.op == desc.op && resolved.typed && resolved.cascade_ok);
        assert(resolved.scalar_type == desc.destination);
        assert(resolved.source_type == desc.source);
        prepare_checker(cat({desc.source_name, " %r0, %r1\n"}));
        assert(instrs.len() == 1 && instrs[0].op == desc.op);
        assert(instrs[0].scalar_type == desc.destination);
        assert(instrs[0].source_type == desc.source);
        free_checker();
    }
    String[] invalid = {
        "cvt.f32.f32", "cvt.i32.i64", "cvt.f16.f32", "bitcast.f64.u32",
        "bitcast.i32.f32.more", "cvt", "bitcast",
    };
    foreach (name : invalid) {
        OpDesc rejected;
        assert(!resolve_op_desc(name, &rejected));
    }
}


fn void float_arithmetic_and_comparisons_resolve_as_a_closed_surface() @test {
    String[] names = {
        "add.f32", "sub.f32", "mul.f32", "div.f32", "feq.f32", "fne.f32",
        "flt.f32", "fle.f32", "fgt.f32", "fge.f32", "add.f64", "sub.f64",
        "mul.f64", "div.f64", "feq.f64", "fne.f64", "flt.f64", "fle.f64",
        "fgt.f64", "fge.f64",
    };
    foreach (name : names) {
        OpDesc desc;
        assert(resolve_op_desc(name, &desc));
        assert(desc.op == Op.ALU3 && desc.typed && desc.cascade_ok);
        assert(desc.scalar_type == ScalarType.F32 || desc.scalar_type == ScalarType.F64);
    }
    OpDesc desc;
    assert(resolve_op_desc("feq.f32", &desc) && desc.alu_op == AluOp.FEQ);
    assert(resolve_op_desc("fne.f64", &desc) && desc.alu_op == AluOp.FNE);
    String[] invalid = {
        "feq.i32", "fne.u64", "flt.i64", "cadd.f32", "mod.f32", "mod.f64",
        "inc.f32", "slt.f32", "ult.f32", "and.f64", "shr.f64",
    };
    foreach (name : invalid) assert(!resolve_op_desc(name, &desc));
}
