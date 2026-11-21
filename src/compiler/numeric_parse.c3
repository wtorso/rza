module rez3asm;

fn bool typed_immediate_error(String text, ScalarType type, int line) {
	TypeDesc* desc = scalar_type_desc(type);
	assert(desc != null);
	viol(line, "STRUCT", cat({
		"immediate out of ", desc.source_name, " range: ", text
	}));
	return false;
}

fn ulong typed_max_bits(ScalarType type) {
	TypeDesc* desc = scalar_type_desc(type);
	assert(desc != null && desc.bit_width > 0 && desc.bit_width <= 64);
	if (desc.bit_width == 64) return ulong::max;
	return (1UL << desc.bit_width) - 1;
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
	if (parsed > typed_max_bits(type)) return typed_immediate_error(text, type, line);
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
	TypeDesc* desc = scalar_type_desc(type);
	assert(desc != null && desc.bit_width > 0 && desc.bit_width <= 64);
	if (desc.bit_width == 64) {
		if (desc.signedness != Signedness.UNSIGNED || text[0] == '-') {
			return typed_immediate_error(text, type, line);
		}
		ulong? parsed = text.to_ulong();
		if (catch parsed) return typed_immediate_error(text, type, line);
		*immediate = { .bits = parsed, .literal_kind = LiteralKind.DECIMAL };
		return true;
	}
	long? parsed = text.to_long();
	if (catch parsed) return typed_immediate_error(text, type, line);
	long value = parsed;
	if (desc.signedness == Signedness.SIGNED) {
		long minimum = -(1L << (desc.bit_width - 1));
		long maximum = (1L << (desc.bit_width - 1)) - 1;
		if (value < minimum || value > maximum) return typed_immediate_error(text, type, line);
	} else if (desc.signedness == Signedness.UNSIGNED) {
		if (text[0] == '-' || value < 0 || (ulong)value > typed_max_bits(type)) {
			return typed_immediate_error(text, type, line);
		}
	} else {
		unreachable("typed decimal requires signed or unsigned integer");
	}
	*immediate = {
		.bits = immediate_bits_from_i64(value) & typed_max_bits(type),
		.literal_kind = LiteralKind.DECIMAL,
		.has_negative_sign = text[0] == '-'
	};
	return true;
}

fn bool parse_typed_immediate(String text, ScalarType type, int line, Immediate* immediate) {
	if (type == ScalarType.I64) return parse_i64(text, line, immediate);
	if (text.len == 0) return typed_immediate_error(text, type, line);
	bool negative = text[0] == '-';
	String magnitude = negative ? text[1..] : text;
	bool hex = magnitude.starts_with("0x") || magnitude.starts_with("0X");
	if (hex && negative) return typed_immediate_error(text, type, line);
	if (hex) return parse_typed_hex(text, magnitude, immediate, type, line);
	return parse_typed_decimal(text, immediate, type, line);
}
