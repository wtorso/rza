module rez3asm;

import std::collections::object;
import std::core::dstring;

const int COMPLETION_MAX = 256;

enum CompletionContext : char {
	NONE,
	LAYOUT,
	FRAME,
	CELL,
	MED,
	PROC
}

struct CompletionWriter {
	DString out;
	int count;
	bool overflow;
}

fn void CompletionWriter.init(CompletionWriter* self) {
	self.out = dstring::new(workmem);
	self.count = 0;
	self.overflow = false;
	self.out.append_string(`{"items":[`);
}

fn void CompletionWriter.deinit(CompletionWriter* self) {
	self.out.free();
}

fn void CompletionWriter.append(
	CompletionWriter* self,
	String name,
	int kind,
	String detail,
	String prefix
) {
	if (!name.starts_with(prefix)) return;
	if (name.len > NAV_NAME_MAX) {
		self.overflow = true;
		return;
	}
	if (self.count >= COMPLETION_MAX) {
		self.overflow = true;
		return;
	}
	if (self.count > 0) self.out.append_char(',');
	self.out.append_string(`{"label":`);
	json_str(&self.out, name);
	self.out.appendf(`,"kind":%d,"detail":`, kind);
	json_str(&self.out, detail);
	self.out.append_string(`,"sortText":`);
	json_str(&self.out, name);
	self.out.append_string("}");
	self.count++;
}

fn void CompletionWriter.finish(CompletionWriter* self) {
	self.out.append_string(`],"isIncomplete":`);
	self.out.append_string(self.overflow ? "true" : "false");
	self.out.append_string("}");
}

fn void CompletionWriter.close(CompletionWriter* self) {
	assert(self.out.len() <= LSP_RESPONSE_MAX);
}

fn void completion_fields(CompletionWriter* writer, NavPosition* pos, int ci) {
	int li = cells[ci].layout;
	if (li < 0) return;
	String prefix = nav_prefix(pos);
	Layout layout = layouts[li];
	for (int i = 0; i < layout.field_count; i++) {
		LayoutField field = layout_fields[(sz)(layout.first_field + i)];
		writer.append(
			field.name,
			5,
			cat({ scalar_type_desc(field.scalar_type).source_name, " field" }),
			prefix
		);
	}
}

fn void completion_layouts(CompletionWriter* writer, NavPosition* pos) {
	String prefix   = nav_prefix(pos);
	int source_line = pos.line + 1;
	for (int i = 0; i < (int)layouts.len(); i++) {
		if (layouts[i].line >= source_line) continue;
		writer.append(layouts[i].name, 22, "layout", prefix);
	}
}

fn void completion_frames(CompletionWriter* writer, NavPosition* pos, bool allow_field) {
	String prefix   = nav_prefix(pos);
	int scope       = nav_current_proc(pos);
	int source_line = pos.line + 1;
	if (allow_field) writer.append("field", 21, "root frame", prefix);
	for (int i = 1; i < (int)frames.len(); i++) {
		if (frames[i].line >= source_line || find_frame(frames[i].name, scope) < 0) {
			continue;
		}
		writer.append(frames[i].name, 6, "frame", prefix);
	}
}

fn void completion_cells(CompletionWriter* writer, NavPosition* pos) {
	String prefix   = nav_prefix(pos);
	int scope       = nav_current_proc(pos);
	int source_line = pos.line + 1;
	for (int i = 0; i < (int)cells.len(); i++) {
		if (cells[i].line >= source_line || find_cell(cells[i].name, scope) < 0) {
			continue;
		}
		writer.append(cells[i].name, 6, "cell", prefix);
	}
}

fn void completion_meds(CompletionWriter* writer, NavPosition* pos) {
	String prefix   = nav_prefix(pos);
	int scope       = nav_current_proc(pos);
	int source_line = pos.line + 1;
	for (int i = 0; i < (int)meds.len(); i++) {
		if (meds[i].line >= source_line || find_med(meds[i].name, scope) < 0) {
			continue;
		}
		writer.append(meds[i].name, 18, "mediator", prefix);
	}
}

fn void completion_procs(CompletionWriter* writer, NavPosition* pos) {
	String prefix   = nav_prefix(pos);
	int scope       = nav_current_proc(pos);
	int source_line = pos.line + 1;
	for (int i = 0; i < (int)procs.len(); i++) {
		if (procs[i].line >= source_line || scope == i + 1) continue;
		writer.append(procs[i].name, 3, "procedure", prefix);
	}
}

fn CompletionContext memory_completion_context(String op, int commas) {
	OpDesc* desc = find_op_desc(op);
	if (desc == null || !desc.has_access_type) return CompletionContext.NONE;
	if (desc.op == Op.LOAD && commas == 1) return CompletionContext.MED;
	if (desc.op == Op.STORE && commas == 0) return CompletionContext.MED;
	return CompletionContext.NONE;
}

fn CompletionContext completion_context(NavPosition* pos, bool* allow_field) {
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
	*allow_field = true;
	if (op == "cav" && commas == 1) return CompletionContext.FRAME;
	if (op == "res" && commas == 1) return CompletionContext.FRAME;
	if (op == "res" && commas == 2) return CompletionContext.LAYOUT;
	if (op == "med" && commas == 1) return CompletionContext.CELL;
	if (op == "med" && commas == 2) return CompletionContext.FRAME;
	if (op == "view" && commas == 1) return CompletionContext.MED;
	if (op == "raise" && commas == 0) return CompletionContext.CELL;
	if (op == "raise" && commas == 1) return CompletionContext.FRAME;
	if (op == "probe") return CompletionContext.MED;
	CompletionContext memory = memory_completion_context(op, commas);
	if (memory != CompletionContext.NONE) return memory;
	if (op == "call" && commas == 0) return CompletionContext.PROC;
	if (op == "decay" && commas == 0) {
		*allow_field = false;
		return CompletionContext.FRAME;
	}
	return CompletionContext.NONE;
}

fn bool completion_field_access(NavPosition* pos) {
	String line  = nav_line(pos);
	int relative = pos.word_start - pos.line_start;
	return relative > 0 && line[relative - 1] == '.';
}

fn void on_completion(Object* id, Object* params) {
	sz mark = work_arena.mark();
	defer work_arena.reset(mark);
	NavPosition pos;
	if (!nav_prepare(params, &pos)) {
		lsp_respond(id, `{"isIncomplete":false,"items":[]}`);
		return;
	}
	CompletionWriter writer;
	writer.init();
	defer writer.deinit();
	int ci = nav_typed_cell(&pos);
	if (ci >= 0) {
		completion_fields(&writer, &pos, ci);
	} else if (!completion_field_access(&pos)) {
		bool allow_field          = true;
		CompletionContext context = completion_context(&pos, &allow_field);
		switch (context) {
			case CompletionContext.LAYOUT: completion_layouts(&writer, &pos);
			case CompletionContext.FRAME:
				completion_frames(&writer, &pos, allow_field);
			case CompletionContext.CELL: completion_cells(&writer, &pos);
			case CompletionContext.MED: completion_meds(&writer, &pos);
			case CompletionContext.PROC: completion_procs(&writer, &pos);
			default: break;
		}
	}
	writer.finish();
	writer.close();
	lsp_respond(id, writer.out.str_view());
}
