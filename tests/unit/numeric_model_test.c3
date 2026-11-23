module rez3asm;

fn void numeric_type_descriptors_cover_integer_scalars() @test {
    TypeDesc* byte = scalar_type_desc(ScalarType.U8);
    assert(byte != null);
    assert(byte.source_name == "u8");
    assert(byte.bit_width == 8 && byte.alignment_bytes == 1);
    assert(byte.signedness == Signedness.UNSIGNED);
    assert(byte.kind == TypeKind.INTEGER && !byte.storage_only);
    assert(byte.conversion_class == ConversionClass.INTEGER);
    assert(byte.target_capabilities == 0);
    TypeDesc* word = scalar_type_desc(ScalarType.I64);
    assert(word != null);
    assert(word.source_name == "i64");
    assert(word.bit_width == 64 && word.alignment_bytes == 8);
    assert(word.signedness == Signedness.SIGNED);
    assert(word.kind == TypeKind.INTEGER && !word.storage_only);
    assert(find_scalar_type("u8") ?? ScalarType.NONE == ScalarType.U8);
    assert(find_scalar_type("i64") ?? ScalarType.NONE == ScalarType.I64);
    assert(find_scalar_type("i32") ?? ScalarType.NONE == ScalarType.I32);
    assert(find_scalar_type("f32") ?? ScalarType.NONE == ScalarType.F32);
    assert(scalar_type_desc(ScalarType.NONE) == null);
}

fn void numeric_operation_descriptors_cover_shared_surface() @test {
    String[] names = {
        "cav", "layout", "res", "med", "view", "raise", "decay", "probe",
        "load", "loadb", "store", "storeb", "mov", "cvt", "bitcast", "inc", "dec",
        "cinc", "cdec", "add", "sub", "mul", "cadd", "csub", "cmul", "crc32c",
        "div", "mod", "and", "or", "xor", "shl", "shr", "ushr", "slt",
        "feq", "fne", "flt", "fle", "fgt", "fge", "print", "jmp", "brz",
        "brnz", "call", "await"
    };
    foreach (name : names) assert(find_op_desc(name) != null);
    OpDesc desc;
    assert(resolve_op_desc("add.f32", &desc));
    assert(desc.op == Op.ALU3 && desc.scalar_type == ScalarType.F32);
    assert(resolve_op_desc("load.f32", &desc));
    assert(desc.op == Op.LOAD && desc.scalar_type == ScalarType.F32);
    OpDesc* add = find_op_desc("add");
    assert(add.op == Op.ALU3 && add.alu_op == AluOp.ADD && add.has_scalar_type);
    OpDesc* load = find_op_desc("loadb");
    assert(load.op == Op.LOAD && load.has_scalar_type);
    assert(load.scalar_type == ScalarType.U8 && !load.write);
    OpDesc* store = find_op_desc("store");
    assert(store.op == Op.STORE && store.scalar_type == ScalarType.I64 && store.write);
    assert(op_desc_cascade_ok(add, true));
    OpDesc* view = find_op_desc("view");
    assert(op_desc_cascade_ok(view, false));
    assert(!op_desc_cascade_ok(view, true));
    assert(!op_desc_cascade_ok(find_op_desc("call"), false));
    assert(!op_desc_cascade_ok(find_op_desc("cav"), false));
}

fn void numeric_immediates_preserve_signed_bit_patterns() @test {
    Immediate zero = immediate_from_i64(0);
    assert(zero.bits == 0 && zero.literal_kind == LiteralKind.DECIMAL);
    assert(!zero.has_negative_sign && immediate_i64(zero) == 0);
    Immediate minus_one = immediate_from_i64(-1);
    assert(minus_one.bits == ulong::max && minus_one.has_negative_sign);
    assert(immediate_i64(minus_one) == -1);
    long min = -9223372036854775807 - 1;
    long max = 9223372036854775807;
    Immediate minimum = immediate_from_i64(min);
    Immediate maximum = immediate_from_i64(max);
    assert(minimum.bits == 0x8000000000000000);
    assert(maximum.bits == 0x7fffffffffffffff);
    assert(immediate_i64(minimum) == min && immediate_i64(maximum) == max);
    Immediate raw = { .bits = ulong::max, .literal_kind = LiteralKind.HEX_BITS };
    assert(immediate_i64(raw) == -1 && !raw.has_negative_sign);
    assert(immediate_bits_from_i64(min) == 0x8000000000000000);
}

fn void numeric_instruction_semantics_match_legacy_source() @test {
    prepare_checker("res raw, field, 16\nmed raw_m, raw, field\n"
        "mov %r0, -1\nmov %r1, %r0\n"
        "load %r2, [raw_m + 0]\nloadb %r3, [raw_m + 1]\n"
        "store [raw_m + 0], %r0\nstoreb [raw_m + 1], %r0\n"
        "add %r0, %r1, 1\ncadd %r0, %r1, %r2\n"
        "inc %r0\ndec %r0\ncinc %r0\ncdec %r0\n"
        "slt %r4, %r0, %r1\ncrc32c %r5, %r0, %r1\n");
    assert(instrs.len() == 16);
    assert(instrs[2].operand_kind == OperandKind.IMMEDIATE);
    assert(instrs[2].scalar_type == ScalarType.I64);
    assert(instrs[2].immediate.bits == ulong::max);
    assert(instrs[2].immediate.literal_kind == LiteralKind.DECIMAL);
    assert(instrs[2].immediate.has_negative_sign);
    assert(instrs[3].operand_kind == OperandKind.REGISTER && instrs[3].b == 0);
    assert(instrs[4].scalar_type == ScalarType.I64);
    assert(instrs[5].scalar_type == ScalarType.U8);
    assert(instrs[6].scalar_type == ScalarType.I64);
    assert(instrs[7].scalar_type == ScalarType.U8);
    assert(instrs[8].alu_op == AluOp.ADD);
    assert(instrs[8].operand_kind == OperandKind.IMMEDIATE);
    assert(instrs[9].alu_op == AluOp.CADD);
    assert(instrs[9].operand_kind == OperandKind.REGISTER);
    assert(instrs[10].alu_op == AluOp.INC && instrs[10].op == Op.ALU1);
    assert(instrs[11].alu_op == AluOp.DEC && instrs[11].op == Op.ALU1);
    assert(instrs[12].alu_op == AluOp.CADD && instrs[12].op == Op.ALU3);
    assert(instrs[12].immediate.bits == 1);
    assert(instrs[13].alu_op == AluOp.CSUB && instrs[13].op == Op.ALU3);
    assert(instrs[14].alu_op == AluOp.SLT);
    assert(instrs[15].alu_op == AluOp.CRC32C);
    free_checker();
}

fn void numeric_float_instruction_semantics_match_shared_source() @test {
    prepare_checker("add.f32 %r0, %r1, %r2\nfeq.f64 %r3, %r0, %r1\n");
    assert(instrs.len() == 2);
    assert(instrs[0].op == Op.ALU3 && instrs[0].alu_op == AluOp.ADD);
    assert(instrs[0].scalar_type == ScalarType.F32);
    assert(instrs[0].source_type == ScalarType.NONE);
    assert(instrs[1].op == Op.ALU3 && instrs[1].alu_op == AluOp.FEQ);
    assert(instrs[1].scalar_type == ScalarType.F64);
    free_checker();
    start_invalid_layout("mod.f32 %r0, %r1, %r2\n");
    assert(lsp_diags[0].msg == "unknown op mod.f32");
    free_checker();
}

fn void numeric_source_literal_kinds_and_views_are_preserved() @test {
    prepare_checker("mov %r0, -9223372036854775808\nmov %r1, -0x1\n"
        "mov %r2, 0xffffffffffffffff\ncinc %r0\n");
    assert(instrs[0].immediate.bits == 0x8000000000000000);
    assert(instrs[0].immediate.literal_kind == LiteralKind.DECIMAL);
    assert(instrs[0].immediate.has_negative_sign);
    assert(instrs[1].immediate.bits == ulong::max);
    assert(instrs[1].immediate.literal_kind == LiteralKind.HEX_BITS);
    assert(instrs[1].immediate.has_negative_sign);
    assert(instrs[2].immediate.bits == ulong::max);
    assert(instrs[2].immediate.literal_kind == LiteralKind.HEX_BITS);
    assert(!instrs[2].immediate.has_negative_sign);
    assert(instrs[3].alu_op == AluOp.CADD && instrs[3].immediate.bits == 1);
    assert(immediate_i64(instrs[0].immediate) == -9223372036854775807 - 1);
    assert(immediate_i64(instrs[1].immediate) == -1);
    assert(immediate_i64(instrs[2].immediate) == -1);
    free_checker();
    prepare_checker("res raw, field, 16\nmed raw_m, raw, field\n"
        "view static_m, raw_m, 0x1, 8\nview dynamic_m, raw_m, %r0, 0x2\n");
    assert(meds[1].view_offset.operand_kind == OperandKind.IMMEDIATE);
    assert(meds[1].view_offset.immediate.bits == 1);
    assert(meds[1].view_offset.immediate.literal_kind == LiteralKind.HEX_BITS);
    assert(meds[1].view_length.immediate.bits == 8);
    assert(meds[2].view_offset.operand_kind == OperandKind.REGISTER);
    assert(meds[2].view_offset.reg == 0);
    assert(meds[2].view_length.operand_kind == OperandKind.IMMEDIATE);
    assert(meds[2].view_length.immediate.bits == 2);
    assert(meds[2].view_length.immediate.literal_kind == LiteralKind.HEX_BITS);
    free_checker();
}

fn void numeric_lsp_memory_context_uses_operation_descriptors() @test {
    assert(memory_completion_context("load", 1) == CompletionContext.MED);
    assert(memory_completion_context("loadb", 1) == CompletionContext.MED);
    assert(memory_completion_context("store", 0) == CompletionContext.MED);
    assert(memory_completion_context("storeb", 0) == CompletionContext.MED);
    assert(memory_completion_context("load", 0) == CompletionContext.NONE);
    assert(memory_completion_context("store", 1) == CompletionContext.NONE);
    assert(memory_completion_context("load.f32", 1) == CompletionContext.MED);
    assert(memory_completion_context("store.i64", 0) == CompletionContext.MED);
    assert(memory_completion_context("unknown", 1) == CompletionContext.NONE);
}

fn void numeric_layout_metrics_use_descriptor_alignment() @test {
    TypeDesc desc = { .bit_width = 64, .alignment_bytes = 1 };
    int width = 0;
    int alignment = 0;
    type_layout_metrics(&desc, &width, &alignment);
    assert(width == 8);
    assert(alignment == 1);
}

fn void numeric_unknown_op_preserves_sync_cascade_diagnostic() @test {
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "casc c: raw_m -> out[field]\nmystery\nendc\nret\n", 4, "STRUCT",
        "op mystery not allowed in cascade body (data instructions only)");
}

fn void numeric_unknown_op_preserves_async_cascade_diagnostic() @test {
    expect_layout_error("res raw, field, 8\nmed raw_m, raw, field\n"
        "acasc c: raw_m -> out\nmystery\nendc\nawait %r0\nret\n", 4, "STRUCT",
        "op mystery not allowed in async cascade body (data instructions only)");
}
