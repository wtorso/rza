module rez3asm;

import std::collections::object;
import std::core::dstring;

const int REFERENCE_OCCURRENCE_MAX =  4096;
const int LSP_REQUEST_FAILED       = -32803;

struct ReferenceOccurrence {
	int line;
	int line_start;
	int start;
	int end;
	bool declaration;
}

ReferenceOccurrence[REFERENCE_OCCURRENCE_MAX] reference_occurrences;
int reference_occurrence_count;
bool reference_occurrence_overflow;

fn bool reference_same_symbol(NavSymbol left, NavSymbol right) {
	if (left.kind == NavKind.NONE || right.kind == NavKind.NONE) return false;
	return left.kind == right.kind && left.index == right.index;
}

fn bool reference_is_declaration(NavSymbol symbol, NavPosition* pos) {
	if (symbol.kind == NavKind.NONE || symbol.kind == NavKind.BUILTIN_FIELD) return false;
	int column = nav_symbol_column(symbol);
	return symbol.line == pos.line + 1 && column == pos.word_start - pos.line_start;
}

fn NavSymbol reference_field_declaration(NavPosition* pos) {
	String word = nav_word(pos);
	int column  = pos.word_start - pos.line_start;
	for (int i = 0; i < (int)layouts.len(); i++) {
		Layout layout = layouts[i];
		if (layout.line != pos.line + 1) continue;
		for (int j = 0; j < layout.field_count; j++) {
			int index         = layout.first_field + j;
			LayoutField field = layout_fields[index];
			if (field.name_column == column && field.name == word) {
				return { .kind = NavKind.FIELD, .index = index, .aux = i, .line = layout.line };
			}
		}
	}
	return { };
}

fn NavSymbol reference_symbol_at(NavPosition* pos, bool* declaration) {
	NavSymbol symbol = nav_resolve(pos);
	*declaration = reference_is_declaration(symbol, pos);
	if (symbol.kind != NavKind.NONE) return symbol;
	symbol = reference_field_declaration(pos);
	*declaration = symbol.kind != NavKind.NONE;
	return symbol;
}

fn void reference_add(NavPosition* pos, bool declaration) {
	if (reference_occurrence_count >= REFERENCE_OCCURRENCE_MAX) {
		reference_occurrence_overflow = true;
		return;
	}
	reference_occurrences[reference_occurrence_count] = {
		.line = pos.line,
		.line_start = pos.line_start,
		.start = pos.word_start,
		.end = pos.word_end,
		.declaration = declaration
	};
	reference_occurrence_count++;
}

fn NavSymbol reference_linked_symbol(NavSymbol target) {
	if (target.kind == NavKind.PROC) {
		return {
			.kind = NavKind.FRAME,
			.index = procs[target.index].frame,
			.line = procs[target.index].line
		};
	}
	if (target.kind != NavKind.FRAME || !frames[target.index].is_procframe) return { };
	for (int i = 0; i < (int)procs.len(); i++) {
		if (procs[i].frame == target.index) {
			return { .kind = NavKind.PROC, .index = i, .line = procs[i].line };
		}
	}
	return { };
}

fn void reference_scan_line(NavPosition* pos, NavSymbol target, NavSymbol linked, bool for_rename) {
	String text = lsp_doc_text(pos.doc_index);
	int cursor  = pos.line_start;
	while (cursor < pos.line_end && !reference_occurrence_overflow) {
		if (text[cursor] == ';') return;
		if (!nav_word_char(text[cursor])) {
			cursor++;
			continue;
		}
		pos.word_start = cursor;
		while (cursor < pos.line_end && nav_word_char(text[cursor])) cursor++;
		pos.word_end = cursor;
		pos.cursor = cursor;
		bool declaration     = false;
		NavSymbol found      = reference_symbol_at(pos, &declaration);
		bool matches         = reference_same_symbol(
			found,
			target
		) || reference_same_symbol(found, linked);
		bool linked_proc_use = target.kind == NavKind.FRAME && found.kind == NavKind.PROC
			&& !declaration;
		if (matches && (for_rename || !linked_proc_use)) reference_add(pos, declaration);
	}
}

fn void reference_collect(int doc_index, NavSymbol target, bool for_rename) {
	reference_occurrence_count = 0;
	reference_occurrence_overflow = false;
	NavSymbol linked = reference_linked_symbol(target);
	String text      = lsp_doc_text(doc_index);
	int line         = 0;
	int line_start   = 0;
	while (line_start <= (int)text.len && !reference_occurrence_overflow) {
		int raw_end = line_start;
		while (raw_end < (int)text.len && text[raw_end] != '\n') raw_end++;
		int line_end = raw_end;
		if (line_end > line_start && text[line_end - 1] == '\r') line_end--;
		NavPosition pos = {
			.doc_index = doc_index,
			.line = line,
			.line_start = line_start,
			.line_end = line_end
		};
		reference_scan_line(&pos, target, linked, for_rename);
		if (raw_end == (int)text.len) break;
		line_start = raw_end + 1;
		line++;
	}
}

fn bool reference_append_range(
	DString* out,
	String text,
	int line_number,
	int line_start,
	int start,
	int end
) {
	int line_end = line_start;
	while (line_end < (int)text.len && text[line_end] != '\n') line_end++;
	if (line_end > line_start && text[line_end - 1] == '\r') line_end--;
	String line   = nav_slice(text, line_start, line_end);
	sz? utf_start = nav_byte_to_utf16(line, (sz)(start - line_start));
	sz? utf_end   = nav_byte_to_utf16(line, (sz)(end - line_start));
	if (catch utf_start) return false;
	if (catch utf_end) return false;
	out.appendf(`{"start":{"line":%d,"character":%d},`, line_number, utf_start);
	out.appendf(`"end":{"line":%d,"character":%d}}`, line_number, utf_end);
	return true;
}

fn bool reference_append_location(DString* out, int doc_index, ReferenceOccurrence occurrence) {
	out.append_string(`{"uri":`);
	json_str(out, lsp_doc_uri(doc_index));
	out.append_string(`,"range":`);
	bool ok = reference_append_range(
		out,
		lsp_doc_text(doc_index),
		occurrence.line,
		occurrence.line_start,
		occurrence.start,
		occurrence.end
	);
	if (!ok) return false;
	out.append_char('}');
	return true;
}

fn bool reference_write(DString* out, int doc_index, bool include_declaration) {
	out.append_char('[');
	bool first = true;
	for (int i = 0; i < reference_occurrence_count; i++) {
		ReferenceOccurrence occurrence = reference_occurrences[i];
		if (!include_declaration && occurrence.declaration) continue;
		if (!first) out.append_char(',');
		first = false;
		if (!reference_append_location(out, doc_index, occurrence)) return false;
		if (out.len() > (sz)LSP_RESPONSE_MAX) return false;
	}
	out.append_char(']');
	return out.len() <= (sz)LSP_RESPONSE_MAX;
}

fn bool reference_include_declaration(Object* params) {
	Object* context = params.get("context") ?? null;
	if (context == null || !context.is_keyable()) return false;
	Object* include = context.get("includeDeclaration") ?? null;
	return include != null && include.is_bool() && include.b;
}

fn void on_references(Object* id, Object* params) {
	sz mark = work_arena.mark();
	defer work_arena.reset(mark);
	NavPosition pos;
	if (!nav_prepare(params, &pos)) {
		lsp_respond(id, "[]");
		return;
	}
	bool declaration = false;
	NavSymbol target = reference_symbol_at(&pos, &declaration);
	if (target.kind == NavKind.NONE) {
		lsp_respond(id, "[]");
		return;
	}
	reference_collect(pos.doc_index, target, false);
	if (reference_occurrence_overflow) {
		lsp_respond_error(id, LSP_REQUEST_FAILED, "too many references");
		return;
	}
	DString out = dstring::new(workmem);
	defer out.free();
	if (!reference_write(&out, pos.doc_index, reference_include_declaration(params))) {
		lsp_respond_error(id, LSP_REQUEST_FAILED, "cannot serialize references within budget");
		return;
	}
	lsp_respond(id, out.str_view());
}


fn bool reference_renameable(NavSymbol symbol) {
	return symbol.kind != NavKind.NONE && symbol.kind != NavKind.BUILTIN_FIELD;
}

fn void on_prepare_rename(Object* id, Object* params) {
	sz mark = work_arena.mark();
	defer work_arena.reset(mark);
	NavPosition pos;
	if (!nav_prepare(params, &pos)) {
		lsp_respond(id, "null");
		return;
	}
	bool declaration = false;
	NavSymbol target = reference_symbol_at(&pos, &declaration);
	if (!reference_renameable(target)) {
		lsp_respond(id, "null");
		return;
	}
	DString out = dstring::new(workmem);
	defer out.free();
	out.append_string(`{"range":`);
	bool ok = reference_append_range(
		&out,
		lsp_doc_text(pos.doc_index),
		pos.line,
		pos.line_start,
		pos.word_start,
		pos.word_end
	);
	if (!ok) {
		lsp_respond(id, "null");
		return;
	}
	out.append_string(`,"placeholder":`);
	json_str(&out, nav_word(&pos));
	out.append_char('}');
	lsp_respond(id, out.str_view());
}

fn bool rename_name_valid(NavSymbol target, String name) {
	if (target.kind == NavKind.LAYOUT) return is_layout_name(name);
	if (!is_name(name)) return false;
	return target.kind != NavKind.MED || name.ends_with("_m");
}

fn bool rename_build_source(String text, String new_name, DString* out) {
	long new_size = (long)text.len;
	for (int i = 0; i < reference_occurrence_count; i++) {
		ReferenceOccurrence occurrence = reference_occurrences[i];
		new_size += (long)new_name.len - (long)(occurrence.end - occurrence.start);
	}
	if (new_size < 0 || new_size > SOURCE_BYTES_MAX) return false;
	*out = dstring::new_with_capacity(workmem, (sz)new_size);
	int cursor = 0;
	for (int i = 0; i < reference_occurrence_count; i++) {
		ReferenceOccurrence occurrence = reference_occurrences[i];
		assert(occurrence.start >= cursor && occurrence.end >= occurrence.start);
		out.append_string(nav_slice(text, cursor, occurrence.start));
		out.append_string(new_name);
		cursor = occurrence.end;
	}
	out.append_string(nav_slice(text, cursor, text.len));
	assert(out.len() == (sz)new_size);
	return true;
}

fn bool rename_write(DString* out, int doc_index, String new_name) {
	String text = lsp_doc_text(doc_index);
	out.append_string(`{"documentChanges":[{"textDocument":{"uri":`);
	json_str(out, lsp_doc_uri(doc_index));
	out.appendf(`,"version":%d},"edits":[`, lsp_docs[doc_index].version);
	for (int i = 0; i < reference_occurrence_count; i++) {
		ReferenceOccurrence occurrence = reference_occurrences[i];
		if (i > 0) out.append_char(',');
		out.append_string(`{"range":`);
		bool ok = reference_append_range(
			out,
			text,
			occurrence.line,
			occurrence.line_start,
			occurrence.start,
			occurrence.end
		);
		if (!ok) return false;
		out.append_string(`,"newText":`);
		json_str(out, new_name);
		out.append_char('}');
		if (out.len() > (sz)LSP_RESPONSE_MAX) return false;
	}
	out.append_string("]}]}");
	return out.len() <= (sz)LSP_RESPONSE_MAX;
}

fn void on_rename(Object* id, Object* params) {
	sz mark = work_arena.mark();
	defer work_arena.reset(mark);
	NavPosition pos;
	if (!nav_prepare(params, &pos)) {
		lsp_respond_error(id, -32602, "invalid rename position");
		return;
	}
	bool declaration = false;
	NavSymbol target = reference_symbol_at(&pos, &declaration);
	if (!reference_renameable(target)) {
		lsp_respond_error(id, -32602, "symbol is not renameable");
		return;
	}
	String? new_name = params.get_string("newName");
	if (catch new_name) {
		lsp_respond_error(id, -32602, "invalid new name");
		return;
	}
	if (!rename_name_valid(target, new_name)) {
		lsp_respond_error(id, -32602, "invalid new name");
		return;
	}
	if (violations > 0) {
		lsp_respond_error(id, LSP_REQUEST_FAILED, "rename requires a valid document");
		return;
	}
	reference_collect(pos.doc_index, target, true);
	if (reference_occurrence_overflow) {
		lsp_respond_error(id, LSP_REQUEST_FAILED, "too many rename edits");
		return;
	}
	DString renamed;
	if (!rename_build_source(lsp_doc_text(pos.doc_index), new_name, &renamed)) {
		lsp_respond_error(id, LSP_REQUEST_FAILED, "renamed document exceeds source budget");
		return;
	}
	defer renamed.free();
	reset_state();
	run(renamed.str_view());
	if (violations > 0) {
		lsp_respond_error(id, LSP_REQUEST_FAILED, "rename would make the program invalid");
		return;
	}
	DString out = dstring::new(workmem);
	defer out.free();
	if (!rename_write(&out, pos.doc_index, new_name)) {
		lsp_respond_error(id, LSP_REQUEST_FAILED, "cannot serialize rename within budget");
		return;
	}
	lsp_respond(id, out.str_view());
}
