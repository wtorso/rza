module rez3asm;

fn bool typed_immediate_error(String text, ScalarType type, int line) {
	TypeDesc* desc = scalar_type_desc(type);
	assert(desc != null);
	viol(line, "STRUCT", cat({
		"immediate out of ", desc.source_name, " range: ", text
	}));
	return false;
}

fn bool parse_typed_hex(
	String text,
	String magnitude,
	Immediate* immediate,
	ScalarType type,
	int line
) {
	ulong? parsed = magnitude.to_ulong();
	if (catch parsed) return typed_immediate_error(text, type, line);
	if (parsed > 0xff) return typed_immediate_error(text, type, line);
	*immediate = {
		.bits = parsed,
		.literal_kind = LiteralKind.HEX_BITS,
		.has_negative_sign = false
	};
	return true;
}

fn bool parse_typed_decimal(
	String text,
	Immediate* immediate,
	ScalarType type,
	int line
) {
	long? parsed = text.to_long();
	if (catch parsed) return typed_immediate_error(text, type, line);
	long value = parsed;
	if (type == ScalarType.I8) {
		if (value < -128 || value > 127) return typed_immediate_error(text, type, line);
	} else if (type == ScalarType.U8) {
		if (text[0] == '-' || value < 0 || value > 255) {
			return typed_immediate_error(text, type, line);
		}
	} else {
		unreachable("typed decimal requires i8 or u8");
	}
	*immediate = {
		.bits = immediate_bits_from_i64(value) & 0xff,
		.literal_kind = LiteralKind.DECIMAL,
		.has_negative_sign = text[0] == '-'
	};
	return true;
}

fn bool parse_typed_immediate(String text, ScalarType type, int line, Immediate* immediate) {
	if (text.len == 0) return typed_immediate_error(text, type, line);
	bool negative = text[0] == '-';
	String magnitude = negative ? text[1..] : text;
	bool hex = magnitude.starts_with("0x") || magnitude.starts_with("0X");
	if (hex && negative) return typed_immediate_error(text, type, line);
	if (hex) return parse_typed_hex(text, magnitude, immediate, type, line);
	return parse_typed_decimal(text, immediate, type, line);
}
