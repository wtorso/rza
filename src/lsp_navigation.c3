module rez3asm;

import std::collections::object;
import std::core::dstring;

const int NAV_NAME_MAX = 256;

enum NavKind : char {
	NONE,
	LAYOUT,
	FIELD,
	FRAME,
	CELL,
	MED,
	PROC,
	BUILTIN_FIELD
}

struct NavPosition {
	int doc_index;
	int line;
	int line_start;
	int line_end;
	int cursor;
	int word_start;
	int word_end;
}

struct NavSymbol {
	NavKind kind;
	int index;
	int aux;
	int line;
}

fn int nav_codepoint_width(String text, sz pos) {
	if (pos >= text.len) return -1;
	char c    = text[pos];
	int width = 1;
	if ((c & 0x80) == 0) {
		width = 1;
	} else if ((c & 0xE0) == 0xC0) {
		width = 2;
	} else if ((c & 0xF0) == 0xE0) {
		width = 3;
	} else if ((c & 0xF8) == 0xF0) {
		width = 4;
	} else {
		return -1;
	}
	if (pos + (sz)width > text.len) return -1;
	for (int i = 1; i < width; i++) {
		if ((text[pos + (sz)i] & 0xC0) != 0x80) return -1;
	}
	return width;
}

fn sz? nav_utf16_to_byte(String text, sz units) {
	if (units < 0) return NOT_FOUND~;
	sz pos     = 0;
	sz current = 0;
	while (pos < text.len) {
		if (current == units) return pos;
		int width = nav_codepoint_width(text, pos);
		if (width < 0) return NOT_FOUND~;
		sz increment = width == 4 ? 2 : 1;
		if (current + increment > units) return NOT_FOUND~;
		current += increment;
		pos += (sz)width;
	}
	if (current == units) return pos;
	return NOT_FOUND~;
}

fn sz? nav_byte_to_utf16(String text, sz offset) {
	if (offset < 0 || offset > text.len) return NOT_FOUND~;
	sz pos   = 0;
	sz units = 0;
	while (pos < offset) {
		int width = nav_codepoint_width(text, pos);
		if (width < 0 || pos + (sz)width > offset) return NOT_FOUND~;
		units += width == 4 ? 2 : 1;
		pos += (sz)width;
	}
	return units;
}

fn bool nav_line_bounds(String text, int target, int* start, int* end) {
	if (target < 0) return false;
	sz pos = 0;
	for (int current = 0; current < target; current++) {
		sz? newline = text[pos..].index_of_char('\n');
		if (catch newline) return false;
		pos += newline + 1;
	}
	sz finish = pos;
	while (finish < text.len && text[finish] != '\n') finish++;
	if (finish > pos && text[finish - 1] == '\r') finish--;
	*start = (int)pos;
	*end = (int)finish;
	return true;
}

fn bool nav_word_char(char c) {
	return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z';
}

fn String nav_slice(String text, sz start, sz end) {
	assert(start >= 0 && end >= start && end <= text.len);
	if (start == end) return text[start:0];
	return text[start:end - start];
}

fn String nav_line(NavPosition* pos) {
	String text = lsp_doc_text(pos.doc_index);
	return nav_slice(text, pos.line_start, pos.line_end);
}

fn String nav_word(NavPosition* pos) {
	String text = lsp_doc_text(pos.doc_index);
	return nav_slice(text, pos.word_start, pos.word_end);
}

fn String nav_prefix(NavPosition* pos) {
	String text = lsp_doc_text(pos.doc_index);
	return nav_slice(text, pos.word_start, pos.cursor);
}

fn bool nav_parse_position(Object* params, NavPosition* out) {
	Object* td = lsp_text_document(params);
	if (td == null) return false;
	String? uri = td.get_string("uri");
	if (catch uri) return false;
	Object* position = params.get("position") ?? null;
	if (position == null || !position.is_keyable()) return false;
	Object* line      = position.get("line") ?? null;
	Object* character = position.get("character") ?? null;
	if (line == null || character == null) return false;
	if (!line.is_int() || !character.is_int()) return false;
	if (line.i < 0 || line.i > LSP_DOC_MAX) return false;
	if (character.i < 0 || character.i > LSP_DOC_MAX * 2) return false;
	int index = lsp_doc_find(uri);
	if (index < 0) return false;
	int start   = 0;
	int end     = 0;
	String text = lsp_doc_text(index);
	if (!nav_line_bounds(text, (int)line.i, &start, &end)) return false;
	sz? cursor = nav_utf16_to_byte(nav_slice(text, start, end), (sz)character.i);
	if (catch cursor) return false;
	*out = {
		.doc_index = index,
		.line = (int)line.i,
		.line_start = start,
		.line_end = end,
		.cursor = start + (int)cursor
	};
	for (int i = start; i < out.cursor; i++) {
		if (text[i] == ';') return false;
	}
	String line_text = nav_slice(text, start, end);
	sz left          = cursor;
	sz right         = cursor;
	while (left > 0 && nav_word_char(line_text[left - 1])) left--;
	while (right < line_text.len && nav_word_char(line_text[right])) right++;
	out.word_start = start + (int)left;
	out.word_end = start + (int)right;
	return true;
}

fn bool nav_prepare(Object* params, NavPosition* out) {
	if (!nav_parse_position(params, out)) return false;
	reset_state();
	run(lsp_doc_text(out.doc_index));
	return true;
}

fn String nav_symbol_name(NavSymbol symbol) {
	switch (symbol.kind) {
		case NavKind.LAYOUT: return layouts[symbol.index].name;
		case NavKind.FIELD: return layout_fields[symbol.index].name;
		case NavKind.FRAME: return frames[symbol.index].name;
		case NavKind.CELL: return cells[symbol.index].name;
		case NavKind.MED: return meds[symbol.index].name;
		case NavKind.PROC: return procs[symbol.index].name;
		default: return "";
	}
}

fn int nav_symbol_column(NavSymbol symbol) {
	switch (symbol.kind) {
		case NavKind.LAYOUT: return layouts[symbol.index].name_column;
		case NavKind.FIELD: return layout_fields[symbol.index].name_column;
		case NavKind.FRAME: return frames[symbol.index].name_column;
		case NavKind.CELL: return cells[symbol.index].name_column;
		case NavKind.MED: return meds[symbol.index].name_column;
		case NavKind.PROC: return procs[symbol.index].name_column;
		default: return -1;
	}
}

fn String nav_location_json(NavPosition* pos, NavSymbol symbol) {
	String name = nav_symbol_name(symbol);
	if (symbol.line <= 0 || name.len == 0) return "null";
	int start   = 0;
	int end     = 0;
	String text = lsp_doc_text(pos.doc_index);
	if (!nav_line_bounds(text, symbol.line - 1, &start, &end)) return "null";
	String line = nav_slice(text, start, end);
	int column  = nav_symbol_column(symbol);
	if (column < 0 || (sz)column + name.len > line.len) return "null";
	if (nav_slice(line, (sz)column, (sz)column + name.len) != name) return "null";
	sz? utf_start = nav_byte_to_utf16(line, (sz)column);
	sz? utf_end   = nav_byte_to_utf16(line, (sz)column + name.len);
	if (catch utf_start) return "null";
	if (catch utf_end) return "null";
	DString out = dstring::new(workmem);
	defer out.free();
	out.append_string(`{"uri":`);
	json_str(&out, lsp_doc_uri(pos.doc_index));
	out.appendf(`,"range":{"start":{"line":%d,"character":%d},`, symbol.line - 1, utf_start);
	out.appendf(`"end":{"line":%d,"character":%d}}}`, symbol.line - 1, utf_end);
	return out.copy_str(workmem);
}

fn int nav_typed_cell(NavPosition* pos) {
	String line  = nav_line(pos);
	int relative = pos.word_start - pos.line_start;
	if (relative <= 0 || line[relative - 1] != '.') return -1;
	int open = -1;
	int plus = -1;
	for (int i = 0; i < relative - 1; i++) {
		if (line[i] == '[') open = i;
		if (line[i] == '+') plus = i;
		if (line[i] == ';') break;
	}
	if (open < 0 || plus <= open + 1) return -1;
	String name = nav_slice(line, (sz)(open + 1), (sz)plus).trim();
	int mi      = find_med(name, nav_current_proc(pos));
	if (mi < 0 || meds[mi].line >= pos.line + 1) return -1;
	return meds[mi].cell;
}

fn CompletionContext nav_declaration_context(NavPosition* pos) {
	String line  = nav_line(pos);
	int relative = pos.word_start - pos.line_start;
	int start    = 0;
	while (start < relative && (line[start] == ' ' || line[start] == '\t')) start++;
	int end = start;
	while (end < relative && line[end] != ' ' && line[end] != '\t') end++;
	String op  = nav_slice(line, start, end);
	int commas = 0;
	for (int i = end; i < relative; i++) {
		if (line[i] == ',') commas++;
		if (line[i] == ';') break;
	}
	if (relative >= end) {
		if (op == "res" && commas == 0) return CompletionContext.CELL;
		if (op == "med" && commas == 0) return CompletionContext.MED;
		if (op == "proc") return CompletionContext.PROC;
		if (op == "cav" && commas == 0) return CompletionContext.FRAME;
		if (op == "layout" && commas == 0) return CompletionContext.LAYOUT;
	}
	if (op == "casc" || op == "acasc") {
		int colon = -1;
		for (int i = end; i < (int)line.len; i++) {
			if (line[i] == ';') break;
			if (line[i] == '-' && i + 1 < (int)line.len && line[i + 1] == '>') break;
			if (line[i] == ':') {
				colon = i;
				break;
			}
		}
		if (colon >= 0 && relative <= colon) return CompletionContext.NONE;
		int arrow = -1;
		for (int i = end; i + 1 < relative; i++) {
			if (line[i] == '-' && line[i + 1] == '>') arrow = i;
		}
		if (arrow < 0) return CompletionContext.MED;
		for (int i = arrow + 2; i < relative; i++) {
			if (line[i] == ']') return CompletionContext.CELL;
			if (line[i] == '[') return CompletionContext.FRAME;
		}
		return CompletionContext.CELL;
	}
	bool allow_field = true;
	return completion_context(pos, &allow_field);
}

fn NavSymbol nav_resolve(NavPosition* pos) {
	int ci = nav_typed_cell(pos);
	if (ci >= 0) {
		int li = cells[ci].layout;
		if (li < 0) return { };
		int field = find_layout_field(li, nav_word(pos));
		if (field < 0) return { };
		return { .kind = NavKind.FIELD, .index = field, .aux = ci, .line = layouts[li].line };
	}
	if (completion_field_access(pos)) return { };
	String word = nav_word(pos);
	if (word.len == 0) return { };
	CompletionContext context = nav_declaration_context(pos);
	if (context == CompletionContext.LAYOUT) {
		int li = layout_map.get(word) ?? -1;
		if (li >= 0) return { .kind = NavKind.LAYOUT, .index = li, .line = layouts[li].line };
	} else if (context == CompletionContext.PROC) {
		int pi = proc_map.get(word) ?? -1;
		if (pi >= 0) return { .kind = NavKind.PROC, .index = pi, .line = procs[pi].line };
	} else if (context == CompletionContext.MED) {
		int mi = med_map.get(word) ?? -1;
		if (mi >= 0) return { .kind = NavKind.MED, .index = mi, .line = meds[mi].line };
	} else if (context == CompletionContext.CELL) {
		int cell_index = cell_map.get(word) ?? -1;
		if (cell_index >= 0) {
			return { .kind = NavKind.CELL, .index = cell_index, .line = cells[cell_index].line };
		}
	} else if (context == CompletionContext.FRAME) {
		if (word == "field") return { .kind = NavKind.BUILTIN_FIELD };
		int fi = frame_map.get(word) ?? -1;
		if (fi >= 0) return { .kind = NavKind.FRAME, .index = fi, .line = frames[fi].line };
	}
	return { };
}

fn void nav_append_cell_summary(DString* out, int ci) {
	int li = cells[ci].layout;
	if (li >= 0) {
		out.appendf(
			"layout `%s[%d]`; %d bytes.",
			clip_utf8(layouts[li].name, NAV_NAME_MAX),
			cells[ci].element_count,
			cells[ci].size
		);
	} else {
		out.appendf("raw cell; %d bytes.", cells[ci].size);
	}
}

fn String nav_hover_text(NavSymbol symbol) {
	DString out = dstring::new(workmem);
	defer out.free();
	out.append_string("```rza\n");
	if (symbol.kind == NavKind.LAYOUT) {
		Layout layout = layouts[symbol.index];
		out.appendf(
			"layout %s\n```\nstride %d bytes; alignment %d bytes.",
			clip_utf8(layout.name, NAV_NAME_MAX),
			layout.size_bytes,
			layout.alignment_bytes
		);
	} else if (symbol.kind == NavKind.FIELD) {
		LayoutField field = layout_fields[symbol.index];
		int li            = cells[symbol.aux].layout;
		out.appendf(
			"%s\n```\n%s field of `%s`; offset %d bytes.",
			clip_utf8(field.name, NAV_NAME_MAX),
			field.scalar_type == ScalarType.U8 ? "u8" : "i64",
			clip_utf8(layouts[li].name, NAV_NAME_MAX),
			field.offset_bytes
		);
	} else if (symbol.kind == NavKind.FRAME) {
		Frame frame   = frames[symbol.index];
		String parent = frame.parent >= 0 ? frames[frame.parent].name : "-";
		out.appendf(
			"cav %s\n```\nparent frame `%s`; capacity %d bytes.",
			clip_utf8(frame.name, NAV_NAME_MAX),
			clip_utf8(parent, NAV_NAME_MAX),
			frame.cap
		);
	} else if (symbol.kind == NavKind.CELL) {
		out.appendf("res %s\n```\n", clip_utf8(cells[symbol.index].name, NAV_NAME_MAX));
		nav_append_cell_summary(&out, symbol.index);
	} else if (symbol.kind == NavKind.MED) {
		int ci     = meds[symbol.index].cell;
		int issuer = meds[symbol.index].issuer;
		out.appendf(
			"med %s\n```\nmediator for cell `%s`; issuer frame `%s`; ",
			clip_utf8(meds[symbol.index].name, NAV_NAME_MAX),
			clip_utf8(cells[ci].name, NAV_NAME_MAX),
			clip_utf8(frames[issuer].name, NAV_NAME_MAX)
		);
		nav_append_cell_summary(&out, ci);
	} else if (symbol.kind == NavKind.PROC) {
		out.appendf(
			"proc %s\n```\ncell-based parameter and result exchange.",
			clip_utf8(procs[symbol.index].name, NAV_NAME_MAX)
		);
	} else if (symbol.kind == NavKind.BUILTIN_FIELD) {
		out.append_string("field\n```\nimmortal root frame.");
	}
	return out.copy_str(workmem);
}

fn String nav_hover_json(NavSymbol symbol) {
	String text = nav_hover_text(symbol);
	if (text.len == 0) return "null";
	DString out = dstring::new(workmem);
	defer out.free();
	out.append_string(`{"contents":{"kind":"markdown","value":`);
	json_str(&out, text);
	out.append_string("}}");
	return out.copy_str(workmem);
}

fn void on_hover(Object* id, Object* params) {
	sz mark = work_arena.mark();
	defer work_arena.reset(mark);
	NavPosition pos;
	if (!nav_prepare(params, &pos)) {
		lsp_respond(id, "null");
		return;
	}
	NavSymbol symbol = nav_resolve(&pos);
	if (symbol.kind == NavKind.NONE) {
		lsp_respond(id, "null");
		return;
	}
	lsp_respond(id, nav_hover_json(symbol));
}

fn void on_definition(Object* id, Object* params) {
	sz mark = work_arena.mark();
	defer work_arena.reset(mark);
	NavPosition pos;
	if (!nav_prepare(params, &pos)) {
		lsp_respond(id, "null");
		return;
	}
	NavSymbol symbol = nav_resolve(&pos);
	if (symbol.kind == NavKind.NONE) {
		lsp_respond(id, "null");
		return;
	}
	lsp_respond(id, nav_location_json(&pos, symbol));
}

fn int nav_current_proc(NavPosition* pos) {
	int source_line = pos.line + 1;
	for (int i = 0; i < (int)procs.len(); i++) {
		if (source_line < procs[i].line) continue;
		if (procs[i].end_line == 0 || source_line <= procs[i].end_line) return i + 1;
	}
	return 0;
}
