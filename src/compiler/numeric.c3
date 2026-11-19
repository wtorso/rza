module rez3asm;

enum OperandKind : char {
	NONE,
	REGISTER,
	IMMEDIATE
}

enum LiteralKind : char {
	NONE,
	DECIMAL,
	HEX_BITS
}

enum AluOp : char {
	NONE,
	ADD,
	SUB,
	MUL,
	CADD,
	CSUB,
	CMUL,
	INC,
	DEC,
	CINC,
	CDEC,
	AND,
	OR,
	XOR,
	SLT,
	DIV,
	MOD,
	SHL,
	SHR,
	USHR,
	CRC32C
}

enum TypeKind : char {
	INTEGER
}

enum Signedness : char {
	NONE,
	SIGNED,
	UNSIGNED
}

enum ConversionClass : char {
	INTEGER
}

struct Immediate {
	ulong bits;
	LiteralKind literal_kind;
	bool has_negative_sign;
}

struct TypeDesc {
	String source_name;
	ScalarType type;
	TypeKind kind;
	uint bit_width;
	uint alignment_bytes;
	Signedness signedness;
	bool storage_only;
	ConversionClass conversion_class;
	uint target_capabilities;
}

const TypeDesc[] TYPE_DESCS = {
	{
		.source_name = "u8",
		.type = ScalarType.U8,
		.kind = TypeKind.INTEGER,
		.bit_width = 8,
		.alignment_bytes = 1,
		.signedness = Signedness.UNSIGNED,
		.storage_only = false,
		.conversion_class = ConversionClass.INTEGER,
		.target_capabilities = 0
	},
	{
		.source_name = "i64",
		.type = ScalarType.I64,
		.kind = TypeKind.INTEGER,
		.bit_width = 64,
		.alignment_bytes = 8,
		.signedness = Signedness.SIGNED,
		.storage_only = false,
		.conversion_class = ConversionClass.INTEGER,
		.target_capabilities = 0
	}
};

struct OpDesc {
	String source_name;
	Op op;
	AluOp alu_op;
	ScalarType access_type;
	bool has_access_type;
	bool write;
	bool cascade_ok;
	bool sync_only;
}

const OpDesc[] OP_DESCS = {
	{ .source_name = "cav", .op = Op.CAV },
	{ .source_name = "layout", .op = Op.LAYOUT },
	{ .source_name = "res", .op = Op.RES },
	{ .source_name = "med", .op = Op.MED },
	{ .source_name = "view", .op = Op.VIEW, .cascade_ok = true, .sync_only = true },
	{ .source_name = "raise", .op = Op.RAISE },
	{ .source_name = "decay", .op = Op.DECAY },
	{ .source_name = "probe", .op = Op.PROBE },
	{ .source_name = "load", .op = Op.LOAD, .access_type = ScalarType.I64,
		.has_access_type = true, .cascade_ok = true },
	{ .source_name = "loadb", .op = Op.LOAD, .access_type = ScalarType.U8,
		.has_access_type = true, .cascade_ok = true },
	{ .source_name = "store", .op = Op.STORE, .access_type = ScalarType.I64,
		.has_access_type = true, .write = true, .cascade_ok = true },
	{ .source_name = "storeb", .op = Op.STORE, .access_type = ScalarType.U8,
		.has_access_type = true, .write = true, .cascade_ok = true },
	{ .source_name = "mov", .op = Op.MOV, .cascade_ok = true },
	{ .source_name = "inc", .op = Op.ALU1, .alu_op = AluOp.INC, .cascade_ok = true },
	{ .source_name = "dec", .op = Op.ALU1, .alu_op = AluOp.DEC, .cascade_ok = true },
	{ .source_name = "cinc", .op = Op.ALU1, .alu_op = AluOp.CINC, .cascade_ok = true },
	{ .source_name = "cdec", .op = Op.ALU1, .alu_op = AluOp.CDEC, .cascade_ok = true },
	{ .source_name = "add", .op = Op.ALU3, .alu_op = AluOp.ADD, .cascade_ok = true },
	{ .source_name = "sub", .op = Op.ALU3, .alu_op = AluOp.SUB, .cascade_ok = true },
	{ .source_name = "mul", .op = Op.ALU3, .alu_op = AluOp.MUL, .cascade_ok = true },
	{ .source_name = "cadd", .op = Op.ALU3, .alu_op = AluOp.CADD, .cascade_ok = true },
	{ .source_name = "csub", .op = Op.ALU3, .alu_op = AluOp.CSUB, .cascade_ok = true },
	{ .source_name = "cmul", .op = Op.ALU3, .alu_op = AluOp.CMUL, .cascade_ok = true },
	{ .source_name = "crc32c", .op = Op.ALU3, .alu_op = AluOp.CRC32C, .cascade_ok = true },
	{ .source_name = "div", .op = Op.ALU3, .alu_op = AluOp.DIV, .cascade_ok = true },
	{ .source_name = "mod", .op = Op.ALU3, .alu_op = AluOp.MOD, .cascade_ok = true },
	{ .source_name = "and", .op = Op.ALU3, .alu_op = AluOp.AND, .cascade_ok = true },
	{ .source_name = "or", .op = Op.ALU3, .alu_op = AluOp.OR, .cascade_ok = true },
	{ .source_name = "xor", .op = Op.ALU3, .alu_op = AluOp.XOR, .cascade_ok = true },
	{ .source_name = "shl", .op = Op.ALU3, .alu_op = AluOp.SHL, .cascade_ok = true },
	{ .source_name = "shr", .op = Op.ALU3, .alu_op = AluOp.SHR, .cascade_ok = true },
	{ .source_name = "ushr", .op = Op.ALU3, .alu_op = AluOp.USHR, .cascade_ok = true },
	{ .source_name = "slt", .op = Op.ALU3, .alu_op = AluOp.SLT, .cascade_ok = true },
	{ .source_name = "print", .op = Op.PRINT, .cascade_ok = true },
	{ .source_name = "jmp", .op = Op.JMP, .cascade_ok = true },
	{ .source_name = "brz", .op = Op.BRZ, .cascade_ok = true },
	{ .source_name = "brnz", .op = Op.BRNZ, .cascade_ok = true },
	{ .source_name = "call", .op = Op.CALL },
	{ .source_name = "await", .op = Op.AWAIT }
};

fn TypeDesc* scalar_type_desc(ScalarType type) {
	for (usz i = 0; i < TYPE_DESCS.len; i++) {
		if (TYPE_DESCS[i].type == type) return &TYPE_DESCS[i];
	}
	return null;
}

fn void type_layout_metrics(TypeDesc* desc, int* width, int* alignment) {
	assert(desc != null && width != null && alignment != null);
	assert(desc.bit_width > 0 && desc.bit_width % 8 == 0);
	assert(desc.alignment_bytes == 1 || desc.alignment_bytes == 8);
	*width = (int)(desc.bit_width / 8);
	*alignment = (int)desc.alignment_bytes;
}

fn ScalarType? find_scalar_type(String source_name) {
	for (usz i = 0; i < TYPE_DESCS.len; i++) {
		if (TYPE_DESCS[i].source_name == source_name) return TYPE_DESCS[i].type;
	}
	return NOT_FOUND~;
}

fn OpDesc* find_op_desc(String source_name) {
	for (usz i = 0; i < OP_DESCS.len; i++) {
		if (OP_DESCS[i].source_name == source_name) return &OP_DESCS[i];
	}
	return null;
}

fn bool op_desc_cascade_ok(OpDesc* desc, bool is_async) {
	assert(desc != null);
	return desc.cascade_ok && (!is_async || !desc.sync_only);
}

fn ulong immediate_bits_from_i64(long value) {
	if (value >= 0) return (ulong)value;
	return ~(ulong)(-(value + 1));
}

fn long immediate_i64(Immediate value) {
	if (value.bits <= (ulong)long::max) return (long)value.bits;
	return -1 - (long)(ulong::max - value.bits);
}

fn Immediate immediate_from_i64(long value) {
	return {
		.bits = immediate_bits_from_i64(value),
		.literal_kind = LiteralKind.DECIMAL,
		.has_negative_sign = value < 0
	};
}
