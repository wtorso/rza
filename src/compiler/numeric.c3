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
	CRC32C,
	ULT
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
	bool typed_syntax;
}

const TypeDesc[] TYPE_DESCS = {
	{
		.source_name = "i8",
		.type = ScalarType.I8,
		.kind = TypeKind.INTEGER,
		.bit_width = 8,
		.alignment_bytes = 1,
		.signedness = Signedness.SIGNED,
		.storage_only = false,
		.conversion_class = ConversionClass.INTEGER,
		.target_capabilities = 0,
		.typed_syntax = true
	},
	{
		.source_name = "u8",
		.type = ScalarType.U8,
		.kind = TypeKind.INTEGER,
		.bit_width = 8,
		.alignment_bytes = 1,
		.signedness = Signedness.UNSIGNED,
		.storage_only = false,
		.conversion_class = ConversionClass.INTEGER,
		.target_capabilities = 0,
		.typed_syntax = true
	},
	{
		.source_name = "i16",
		.type = ScalarType.I16,
		.kind = TypeKind.INTEGER,
		.bit_width = 16,
		.alignment_bytes = 2,
		.signedness = Signedness.SIGNED,
		.storage_only = false,
		.conversion_class = ConversionClass.INTEGER,
		.target_capabilities = 0,
		.typed_syntax = true
	},
	{
		.source_name = "u16",
		.type = ScalarType.U16,
		.kind = TypeKind.INTEGER,
		.bit_width = 16,
		.alignment_bytes = 2,
		.signedness = Signedness.UNSIGNED,
		.storage_only = false,
		.conversion_class = ConversionClass.INTEGER,
		.target_capabilities = 0,
		.typed_syntax = true
	},
	{
		.source_name = "i32",
		.type = ScalarType.I32,
		.kind = TypeKind.INTEGER,
		.bit_width = 32,
		.alignment_bytes = 4,
		.signedness = Signedness.SIGNED,
		.storage_only = false,
		.conversion_class = ConversionClass.INTEGER,
		.target_capabilities = 0,
		.typed_syntax = true
	},
	{
		.source_name = "u32",
		.type = ScalarType.U32,
		.kind = TypeKind.INTEGER,
		.bit_width = 32,
		.alignment_bytes = 4,
		.signedness = Signedness.UNSIGNED,
		.storage_only = false,
		.conversion_class = ConversionClass.INTEGER,
		.target_capabilities = 0,
		.typed_syntax = true
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
		.target_capabilities = 0,
		.typed_syntax = false
	}
};

struct OpDesc {
	String source_name;
	Op op;
	AluOp alu_op;
	ScalarType scalar_type;
	bool has_scalar_type;
	bool write;
	bool cascade_ok;
	bool sync_only;
	bool typed;
	bool typed_enabled;
	bool typed_only;
	Signedness required_signedness;
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
	{ .source_name = "load", .op = Op.LOAD, .scalar_type = ScalarType.I64,
		.has_scalar_type = true, .cascade_ok = true, .typed_enabled = true },
	{ .source_name = "loadb", .op = Op.LOAD, .scalar_type = ScalarType.U8,
		.has_scalar_type = true, .cascade_ok = true },
	{ .source_name = "store", .op = Op.STORE, .scalar_type = ScalarType.I64,
		.has_scalar_type = true, .write = true, .cascade_ok = true, .typed_enabled = true },
	{ .source_name = "storeb", .op = Op.STORE, .scalar_type = ScalarType.U8,
		.has_scalar_type = true, .write = true, .cascade_ok = true },
	{ .source_name = "mov", .op = Op.MOV, .scalar_type = ScalarType.I64,
		.has_scalar_type = true, .cascade_ok = true, .typed_enabled = true },
	{ .source_name = "inc", .op = Op.ALU1, .alu_op = AluOp.INC,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "dec", .op = Op.ALU1, .alu_op = AluOp.DEC,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "cinc", .op = Op.ALU1, .alu_op = AluOp.CINC,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "cdec", .op = Op.ALU1, .alu_op = AluOp.CDEC,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "add", .op = Op.ALU3, .alu_op = AluOp.ADD,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "sub", .op = Op.ALU3, .alu_op = AluOp.SUB,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "mul", .op = Op.ALU3, .alu_op = AluOp.MUL,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "cadd", .op = Op.ALU3, .alu_op = AluOp.CADD,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "csub", .op = Op.ALU3, .alu_op = AluOp.CSUB,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "cmul", .op = Op.ALU3, .alu_op = AluOp.CMUL,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "crc32c", .op = Op.ALU3, .alu_op = AluOp.CRC32C,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true },
	{ .source_name = "div", .op = Op.ALU3, .alu_op = AluOp.DIV,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "mod", .op = Op.ALU3, .alu_op = AluOp.MOD,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "and", .op = Op.ALU3, .alu_op = AluOp.AND,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "or", .op = Op.ALU3, .alu_op = AluOp.OR,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "xor", .op = Op.ALU3, .alu_op = AluOp.XOR,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "shl", .op = Op.ALU3, .alu_op = AluOp.SHL,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "shr", .op = Op.ALU3, .alu_op = AluOp.SHR,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true, .required_signedness = Signedness.SIGNED },
	{ .source_name = "ushr", .op = Op.ALU3, .alu_op = AluOp.USHR,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true },
	{ .source_name = "slt", .op = Op.ALU3, .alu_op = AluOp.SLT,
		.scalar_type = ScalarType.I64, .has_scalar_type = true, .cascade_ok = true,
		.typed_enabled = true, .required_signedness = Signedness.SIGNED },
	{ .source_name = "ult", .op = Op.ALU3, .alu_op = AluOp.ULT, .cascade_ok = true,
		.typed_enabled = true, .typed_only = true,
		.required_signedness = Signedness.UNSIGNED },
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
	assert(desc.alignment_bytes == 1 || desc.alignment_bytes == 2 ||
		desc.alignment_bytes == 4 || desc.alignment_bytes == 8);
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

fn bool resolve_typed_op_desc(String source_name, OpDesc* out) {
	sz? separator = source_name.index_of_char('.');
	if (catch separator) return false;
	if (separator == 0 || separator + 1 >= source_name.len) return false;
	String base = source_name[:separator];
	String suffix = source_name[separator + 1..];
	if (@ok(suffix.index_of_char('.'))) return false;
	OpDesc* desc = find_op_desc(base);
	if (desc == null || !desc.typed_enabled) return false;
	ScalarType type = find_scalar_type(suffix) ?? ScalarType.NONE;
	TypeDesc* type_desc = scalar_type_desc(type);
	if (type_desc == null || !type_desc.typed_syntax) return false;
	if (desc.required_signedness != Signedness.NONE &&
			desc.required_signedness != type_desc.signedness) return false;
	*out = *desc;
	out.source_name = source_name;
	out.scalar_type = type;
	out.has_scalar_type = true;
	out.typed = true;
	return true;
}

fn bool resolve_op_desc(String source_name, OpDesc* out) {
	OpDesc* desc = find_op_desc(source_name);
	if (desc != null) {
		if (desc.typed_only) return false;
		*out = *desc;
		return true;
	}
	return resolve_typed_op_desc(source_name, out);
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
