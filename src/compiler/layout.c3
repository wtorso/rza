module rez3asm;

const int LAYOUT_MAX              = 256;
const int LAYOUT_FIELDS_PER_MAX   = 64;
const int LAYOUT_FIELDS_TOTAL_MAX = NODE_MAX;

fn int find_layout(String name) {
	if (name.len == 0) return -1;
	return layout_map.get(name) ?? -1;
}

fn int find_layout_field(int layout_index, String name) {
	if (layout_index < 0 || layout_index >= (int)layouts.len()) return -1;
	Layout layout = layouts[layout_index];
	for (int i = 0; i < layout.field_count; i++) {
		int field_index = layout.first_field + i;
		if (layout_fields[field_index].name == name) return field_index;
	}
	return -1;
}

fn bool is_layout_name(String name) {
	if (name.len == 0 || name[0] < 'A' || name[0] > 'Z') return false;
	for (usz i = 1; i < name.len; i++) {
		char c  = name[i];
		bool ok = c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z';
		if (!ok) return false;
	}
	return true;
}

fn int scalar_width(ScalarType type) {
	return type == ScalarType.U8 ? 1 : 8;
}

fn int align_layout_offset(int offset, int alignment) {
	assert(alignment == 1 || alignment == 8);
	int mask = alignment - 1;
	if (offset < 0 || offset > CELL_SIZE_BYTES_MAX - mask) return -1;
	return (offset + mask) & ~mask;
}

fn bool parse_layout_field(String text, int line, LayoutField* field) {
	if (text.len == 0) {
		viol(line, "STRUCT", "empty layout field");
		return false;
	}
	sz? colon = text.index_of_char(':');
	if (catch colon) {
		viol(line, "STRUCT", cat({ "malformed layout field ", text }));
		return false;
	}
	String name      = text[:colon].trim();
	String type_name = text[colon + 1..].trim();
	if (!check_name(name, line)) return false;
	ScalarType type;
	if (type_name == "u8") {
		type = ScalarType.U8;
	} else if (type_name == "i64") {
		type = ScalarType.I64;
	} else {
		viol(line, "STRUCT", cat({ "unknown layout scalar type ", type_name }));
		return false;
	}
	*field = { .name = name, .name_column = source_column(name), .scalar_type = type };
	return true;
}

fn int parse_layout_fields(
	String text,
	int line,
	LayoutField[] fields,
	int* size_bytes,
	int* alignment_bytes
) {
	String[LAYOUT_FIELDS_PER_MAX + 1] parts;
	int count = split_ops(text, &parts);
	if (count < 1 || count > LAYOUT_FIELDS_PER_MAX) {
		viol(line, "STRUCT", "layout must contain 1..64 fields");
		return -1;
	}
	int offset    = 0;
	int alignment = 1;
	for (int i = 0; i < count; i++) {
		LayoutField field;
		if (!parse_layout_field(parts[i], line, &field)) return -1;
		for (int j = 0; j < i; j++) {
			if (fields[j].name == field.name) {
				viol(line, "DUP", cat({ "duplicate layout field ", field.name }));
				return -1;
			}
		}
		int width = scalar_width(field.scalar_type);
		if (width > alignment) alignment = width;
		int field_offset = align_layout_offset(offset, width);
		if (field_offset < 0 || field_offset > CELL_SIZE_BYTES_MAX - width) {
			viol(line, "STRUCT", "layout size out of i32 range");
			return -1;
		}
		field.offset_bytes = field_offset;
		fields[i] = field;
		offset = field_offset + width;
	}
	int size = align_layout_offset(offset, alignment);
	if (size < 0) {
		viol(line, "STRUCT", "layout size out of i32 range");
		return -1;
	}
	*size_bytes = size;
	*alignment_bytes = alignment;
	return count;
}

fn void op_layout(String rest, int line) {
	if (cur_proc > 0 || cur_casc >= 0) {
		viol(line, "STRUCT", "layout declaration must be top-level");
		return;
	}
	if (top_ret > 0) return;
	sz? colon = rest.index_of_char(':');
	if (catch colon) {
		viol(line, "STRUCT", "malformed layout declaration");
		return;
	}
	String name = rest[:colon].trim();
	if (!is_layout_name(name)) {
		viol(line, "STRUCT", cat({ "bad layout name ", name }));
		return;
	}
	if (layout_map.has_key(name)) {
		viol(line, "DUP", cat({ "duplicate layout ", name }));
		return;
	}
	if (layouts.len() >= LAYOUT_MAX) {
		viol(line, "STRUCT", "too many layouts");
		return;
	}
	LayoutField[LAYOUT_FIELDS_PER_MAX] pending;
	int size           = 0;
	int alignment      = 1;
	String fields_text = rest[colon + 1..].trim();
	int count          = parse_layout_fields(fields_text, line, pending[..], &size, &alignment);
	if (count < 0) return;
	if (layout_fields.len() + count > LAYOUT_FIELDS_TOTAL_MAX) {
		viol(line, "STRUCT", "too many layout fields");
		return;
	}
	int first = (int)layout_fields.len();
	for (int i = 0; i < count; i++) layout_fields.push(pending[i]);
	layouts.push(
		{
			.name = name,
			.line = line,
			.name_column = source_column(name),
			.first_field = first,
			.field_count = count,
			.size_bytes = size,
			.alignment_bytes = alignment
		}
	);
	layout_map.set(name, (int)layouts.len() - 1);
}

fn bool parse_layout_use(
	String text,
	int line,
	int* layout_index,
	int* element_count,
	int* size_bytes
) {
	String name = text.trim();
	int count   = 1;
	sz? open    = name.index_of_char('[');
	if (try open) {
		if (name.len < 4 || name[name.len - 1] != ']') {
			viol(line, "STRUCT", cat({ "malformed layout use ", text }));
			return false;
		}
		String count_text = name[open + 1..name.len - 2].trim();
		name = name[:open].trim();
		if (count_text.len == 0) {
			viol(line, "STRUCT", "empty layout element count");
			return false;
		}
		if (!is_int(count_text)) {
			viol(line, "STRUCT", cat({ "bad layout element count ", count_text }));
			return false;
		}
		int? parsed = count_text.to_int();
		if (catch parsed) {
			viol(line, "STRUCT", cat({ "bad layout element count ", count_text }));
			return false;
		}
		if (parsed <= 0) {
			viol(line, "STRUCT", cat({ "bad layout element count ", count_text }));
			return false;
		}
		count = parsed;
	}
	int found = find_layout(name);
	if (found < 0) {
		viol(line, "STRUCT", cat({ "unknown layout ", name }));
		return false;
	}
	int stride = layouts[found].size_bytes;
	if (count > CELL_SIZE_BYTES_MAX / stride) {
		viol(line, "STRUCT", "typed cell size out of i32 range");
		return false;
	}
	*layout_index = found;
	*element_count = count;
	*size_bytes = stride * count;
	return true;
}

fn bool check_typed_access(
	int mediator_index,
	String field_name,
	String opname,
	int index,
	int index_reg,
	int line,
	int* field_index
) {
	Cell* cell = &cells[meds[mediator_index].cell];
	assert(cell.layout >= 0);
	if (field_name.len == 0) {
		viol(line, "STRUCT", cat({ "typed cell requires field selector in ", opname }));
		return false;
	}
	int found = find_layout_field(cell.layout, field_name);
	if (found < 0) {
		viol(line, "STRUCT", cat({ "unknown layout field ", field_name }));
		return false;
	}
	bool byte_op    = opname == "loadb" || opname == "storeb";
	bool byte_field = layout_fields[found].scalar_type == ScalarType.U8;
	if (byte_op != byte_field) {
		viol(line, "STRUCT", cat({ "opcode does not match layout field ", field_name }));
		return false;
	}
	int extent = meds[mediator_index].extent;
	if (index_reg < 0 && (index < 0 || (extent >= 0 && index >= extent))) {
		viol(line, "STRUCT", cat({ opname, " element index out of bounds" }));
		return false;
	}
	int stride = layouts[cell.layout].size_bytes;
	int offset = layout_fields[found].offset_bytes;
	assert(stride > 0);
	assert(cell.element_count > 0);
	assert(offset >= 0 && offset < stride);
	*field_index = found;
	return true;
}

fn void reset_layout_state() {
	layouts.clear();
	layout_fields.clear();
	layout_map.clear();
	assert(layouts.len() == 0);
	assert(layout_fields.len() == 0);
	assert(layout_map.count == 0);
}
