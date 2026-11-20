module rez3asm;

import std::io;
import std::io::file;
import std::core::dstring;
import std::core::mem::allocators;
import std::collections::list;
import std::hash::sha256;

fn void init_state_lists() {
	if (g_state_inited) return;
	frames.init(list_mem, NODE_MAX);
	layouts.init(list_mem, LAYOUT_MAX);
	layout_fields.init(list_mem, LAYOUT_FIELDS_TOTAL_MAX);
	cells.init(list_mem, NODE_MAX);
	meds.init(list_mem, NODE_MAX);
	procs.init(list_mem, NODE_MAX);
	cascades.init(list_mem, NODE_MAX);
	blocks.init(list_mem, NODE_MAX);
	labels.init(list_mem, NODE_MAX);
	instrs.init(list_mem, NODE_MAX);
	lsp_diags.init(list_mem, LSP_DIAG_MAX + 1);
	g_state_inited = true;
}

// полный сброс состояния чекера: CLI зовёт один раз, LSP — на каждую
// валидацию (документ проверяется целиком, Full sync)
fn void reset_state() {
	init_state_lists();
	frames.clear();
	reset_layout_state();
	cells.clear();
	meds.clear();
	procs.clear();
	cascades.clear();
	blocks.clear();
	labels.clear();
	instrs.clear();
	lsp_diags.clear();
	frame_map.clear();
	cell_map.clear();
	med_map.clear();
	proc_map.clear();
	label_map.clear();
	label_names.clear();
	gencnt = 1;
	violations = 0;
	cur_proc = 0;
	cur_casc = -1;
	top_ret = 0;
	casc_seq = 0;
	g_lib_mode = false;
	blocks.push({ .kind = 0, .aux = 0 }); // block 0 = top
	// field — frames[0], бессмертен
	frames.push(
		{
			.name = "field",
			.parent = -1,
			.first_child = -1,
			.next_sibling = -1,
			.alive = true,
			.gen = nextgen(),
			.cname = "f_field",
			.scope = 0,
			.cap = 64,
			.is_field = true
		}
	);
	frame_map.set("field", 0);
	assert(frames.len() == 1);
	assert(cells.len() == 0);
	assert(meds.len() == 0);
	assert(procs.len() == 0);
	assert(cascades.len() == 0);
	assert(blocks.len() == 1);
	assert(labels.len() == 0);
	assert(instrs.len() == 0);
	assert(lsp_diags.len() == 0);
	assert(frame_map.count == 1);
	assert(cell_map.count == 0);
	assert(med_map.count == 0);
	assert(proc_map.count == 0);
	assert(label_map.count == 0);
	assert(label_names.count == 0);
	assert(gencnt == 2);
	assert(violations == 0);
	assert(cur_proc == 0);
	assert(cur_casc == -1);
	assert(top_ret == 0);
	assert(frames[0].alive);
	assert(frames[0].gen == 1);
}

// --- утилиты -------------------------------------------------------------------
fn uint nextgen() {
	uint g = gencnt;
	gencnt++;
	return g;
}

fn int source_column(String token) {
	if (source_line_raw.len == 0) return -1;
	if (token.ptr < source_line_raw.ptr
		|| token.ptr > source_line_raw.ptr + source_line_raw.len) return -1;
	sz offset = token.ptr - source_line_raw.ptr;
	assert(offset >= 0 && offset <= 2147483647);
	return (int)offset;
}

fn String cat(String[] parts) {
	DString d = dstring::new_with_capacity(workmem, 64);
	foreach (p : parts) d.append_string(p);
	return d.copy_str(workmem);
}

fn String clip_utf8(String s, sz max) {
	if (s.len <= max) return s;
	sz pos = 0;
	while (pos < max) {
		char c   = s[pos];
		sz width = 1;
		if ((c & 0xE0) == 0xC0) {
			width = 2;
		} else if ((c & 0xF0) == 0xE0) {
			width = 3;
		} else if ((c & 0xF8) == 0xF0) {
			width = 4;
		}
		if (pos + width > max) break;
		bool valid = true;
		for (sz j = 1; j < width; j++) {
			if ((s[pos + j] & 0xC0) != 0x80) {
				valid = false;
				break;
			}
		}
		pos += valid ? width : 1;
	}
	return s[:pos];
}

const int LSP_DIAG_MAX = 1000;

fn void viol(int line, String rule, String msg) {
	violations++;
	if (g_lsp_mode) {
		if (lsp_diags.len() < LSP_DIAG_MAX) {
			lsp_diags.push(
				{ .line = line, .rule = rule, .msg = clip_utf8(msg, LSP_DIAG_TEXT_MAX) }
			);
		}
		return;
	}
	io::eprintfn("VIOLATION line %d [%s]: %s", line, rule, msg);
}

fn bool is_name(String s) {
	if (s.len == 0) return false;
	char c0 = s[0];
	if (!((c0 >= 'a' && c0 <= 'z') || c0 == '_')) return false;
	for (sz i = 1; i < s.len; i++) {
		char ch = s[i];
		bool ok = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_';
		if (!ok) return false;
	}
	return true;
}

fn bool is_int(String s) {
	if (s.len == 0) return false;
	usz i = (s[0] == '-') ? 1 : 0;
	if (i == s.len) return false;
	if (s.len > i + 2 && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
		for (usz j = i + 2; j < s.len; j++) {
			char c = s[j];
			if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
				|| (c >= 'A' && c <= 'F'))) return false;
		}
		return true;
	}
	for (; i < s.len; i++) {
		if (s[i] < '0' || s[i] > '9') return false;
	}
	return true;
}

fn bool immediate_error(String text, int line) {
	viol(line, "STRUCT", cat({ "immediate out of i64 range: ", text }));
	return false;
}

fn bool parse_i64_signed(String text, int line, long* value) {
	bool negative    = text[0] == '-';
	String magnitude = negative ? text[1..] : text;
	bool hex         = magnitude.starts_with("0x") || magnitude.starts_with("0X");
	if (hex) {
		ulong? parsed = magnitude.to_ulong();
		if (catch parsed) return immediate_error(text, line);
		ulong u = parsed;
		if (negative) {
			if (u > 0x8000000000000000) return immediate_error(text, line);
			if (u == 0x8000000000000000) {
				*value = -9223372036854775807 - 1;
			} else {
				*value = -(long)u;
			}
		} else if (u > (ulong)long::max) {
			*value = -1 - (long)(ulong::max - u);
		} else {
			*value = (long)u;
		}
	} else {
		long? parsed = text.to_long();
		if (catch parsed) return immediate_error(text, line);
		*value = parsed;
	}
	return true;
}

fn bool parse_i64(String text, int line, Immediate* immediate) {
	long value;
	if (!parse_i64_signed(text, line, &value)) return false;
	*immediate = immediate_from_i64(value);
	immediate.has_negative_sign = text[0] == '-';
	String magnitude = immediate.has_negative_sign ? text[1..] : text;
	if (magnitude.starts_with("0x") || magnitude.starts_with("0X")) {
		immediate.literal_kind = LiteralKind.HEX_BITS;
	}
	return true;
}

fn bool check_name(String name, int line) {
	if (!is_name(name)) {
		viol(line, "STRUCT", cat({ "bad name ", name }));
		return false;
	}
	return true;
}

// разбор регистра %r0..%r15; -1 = ошибка (violation записано)
fn int parse_reg(String tok, int line) {
	if (tok.len >= 3 && tok[0] == '%' && tok[1] == 'r' && is_int(tok[2..])) {
		int r = tok[2..].to_int() ?? -1;
		if (r >= 0 && r <= 15) return r;
	}
	viol(line, "STRUCT", cat({ "bad register ", tok, " (want %r0..%r15)" }));
	return -1;
}

// разбить операнды по запятым в buf; возвращает ЧИСЛО токенов
// (считаются все, даже за пределами buf — лишние ловит split_ops_exact)
fn int split_ops(String rest, String[] buf) {
	int n    = 0;
	String r = rest;
	while (true) {
		sz? ci = r.index_of_char(',');
		if (catch ci) {
			if (n < (int)buf.len) buf[n] = r.trim();
			n++;
			break;
		}
		if (n < (int)buf.len) buf[n] = r[:ci].trim();
		n++;
		r = r[ci + 1..];
	}
	return n;
}

fn bool split_ops_exact(String rest, int want, int line, String opname, String[] buf) {
	int n = split_ops(rest, buf);
	if (n != want) {
		viol(line, "STRUCT", cat({ "bad operands for ", opname }));
		return false;
	}
	for (int i = 0; i < n; i++) {
		if (buf[i].len == 0) {
			viol(line, "STRUCT", cat({ "bad operands for ", opname }));
			return false;
		}
	}
	return true;
}

// --- скоупы ----------------------------------------------------------------------
// возврат: >=0 индекс, -1 unknown. Рамки и ячейки — общая хроника,
// SCOPE для них нет (только медиаторы, find_med)
fn int find_frame(String name, int scope) {
	assert(name.len > 0);
	assert(scope >= 0);
	int? fi = frame_map.get(name);
	if (catch fi) return -1;
	return frames[fi].scope == 0 || frames[fi].scope == scope ? fi : -1;
}

fn int find_cell(String name, int scope) {
	assert(name.len > 0);
	assert(scope >= 0);
	int? ci = cell_map.get(name);
	if (catch ci) return -1;
	return cells[ci].scope == 0 || cells[ci].scope == scope ? ci : -1;
}

fn int find_med(String name, int scope) {
	assert(name.len > 0);
	assert(scope >= 0);
	int? mi = med_map.get(name);
	if (catch mi) return -1;
	if (scope == 0) return meds[mi].scope == 0 ? mi : -1;
	if (meds[mi].scope == scope) return mi;
	if (meds[mi].scope != 0) return -2;
	int fr = cells[meds[mi].cell].owner;
	if (frames[fr].is_field) return mi;
	return frames[fr].is_procframe ? -2 : mi;
}

fn int find_proc(String name) {
	return proc_map.get(name) ?? -1;
}

fn bool med_visible_here(int mi) {
	return meds[mi].cascade < 0 || meds[mi].cascade == cur_casc;
}

fn void cascade_scope_viol(int line, String name) {
	viol(line, "SCOPE", cat({ "mediator ", name, " is not visible outside its cascade" }));
}

// Host API names are unique and checked before C generation.
fn bool host_name_bad(String name, int line) {
	if (name == "boot" || name == "arena_alloc" || name == "deref_cell" || name == "rez3ext_abi"
		|| name == "await"
		|| name.starts_with(
		"frame_"
	) || name.starts_with("med_")) {
		viol(line, "STRUCT", cat({ "procedure name ", name, " collides with lib host API" }));
		return true;
	}
	return false;
}

fn void scope_viol(int line, String kind, String name) {
	viol(
		line,
		"SCOPE",
		cat(
			{
				kind,
				" ",
				name,
				" is not visible from procedure body ",
				"(only proc-locals and field-owned mediators are)"
			}
		)
	);
}

fn bool check_dup(String name, int line, int scope) {
	if (try fi = frame_map.get(name)) {
		if (frames[fi].scope == scope) {
			viol(line, "DUP", cat({ "duplicate name ", name }));
			return false;
		}
	}
	if (try ci = cell_map.get(name)) {
		if (cells[ci].scope == scope) {
			viol(line, "DUP", cat({ "duplicate name ", name }));
			return false;
		}
	}
	if (try mi = med_map.get(name)) {
		if (meds[mi].scope == scope) {
			viol(line, "DUP", cat({ "duplicate name ", name }));
			return false;
		}
	}
	return true;
}

fn bool is_ancestor(int owner, int frame, bool strict) {
	int cur = strict ? frames[owner].parent : owner;
	while (cur >= 0) {
		if (cur == frame) return true;
		cur = frames[cur].parent;
	}
	return false;
}

fn bool med_alive(int mi) {
	assert(mi >= 0);
	assert(mi < (int)meds.len());
	int owner = meds[mi].owner;
	int home  = cells[meds[mi].cell].home;
	if (!frames[owner].alive) return false;
	if (!frames[home].alive) return false;
	if (meds[mi].gen != frames[owner].gen) return false;
	return meds[mi].home_gen == frames[home].gen;
}

fn int subtree_sibling_next(int root, int cur) {
	assert(root >= 0);
	assert(root < (int)frames.len());
	assert(cur >= root);
	assert(cur < (int)frames.len());
	while (cur != root && frames[cur].next_sibling < 0) {
		cur = frames[cur].parent;
	}
	if (cur == root) return -1;
	return frames[cur].next_sibling;
}

fn int subtree_next(int root, int cur) {
	assert(root >= 0);
	assert(root < (int)frames.len());
	assert(cur >= root);
	assert(cur < (int)frames.len());
	if (frames[cur].first_child >= 0) return frames[cur].first_child;
	return subtree_sibling_next(root, cur);
}

fn void kill(int f) {
	uint decay_id = gencnt;
	int cur       = f;
	while (cur >= 0) {
		if (!frames[cur].alive) {
			cur = subtree_sibling_next(f, cur);
			continue;
		}
		frames[cur].alive = false;
		frames[cur].gen = nextgen();
		frames[cur].decay_id = decay_id;
		cur = subtree_next(f, cur);
	}
}

// --- блоки -----------------------------------------------------------------------
fn int cur_block() {
	if (cur_casc >= 0) return cascades[cur_casc].block;
	if (cur_proc > 0) return procs[(sz)(cur_proc - 1)].block;
	return 0;
}

fn int cur_func() {
	return cur_proc;
} // 0 = main

fn bool at_capacity(sz len, int line, String kind) {
	if (len < NODE_MAX) return false;
	viol(line, "STRUCT", cat({ "too many ", kind }));
	return true;
}

fn void add_instr(Instr ins) {
	if (at_capacity(instrs.len(), ins.line, "instructions")) return;
	ins.func = cur_func();
	ins.block = cur_block();
	instrs.push(ins);
}

fn String label_key(int block, String name) {
	DString key = dstring::new_with_capacity(workmem, name.len + 16);
	key.appendf("%d:%s", block, name);
	return key.str_view();
}

fn void add_label(String name, int line) {
	if (at_capacity(labels.len(), line, "labels")) return;
	int bid = cur_block();
	if (label_map.has_key(label_key(bid, name))) {
		viol(line, "DUP", cat({ "duplicate label ", name }));
		return;
	}
	labels.push({ .name = name, .line = line, .block = bid, .referenced = false });
	label_map.set(label_key(bid, name), (int)labels.len() - 1);
	label_names.set(name, 1);
	Instr ins = { .op = Op.LABEL, .line = line, .s1 = name };
	add_instr(ins);
}

// --- операции владения -------------------------------------------------------------
// Заглавные разделители не встречаются в именах языка и не дают коллизий.
fn String cname_for(String prefix, String name) {
	return cur_proc > 0 ? cat({ prefix, "P_", procs[(sz)(cur_proc - 1)].name, "X", name })
		: cat({ prefix, name });
}

fn void link_frame(int frame, int parent) {
	assert(frame > 0);
	assert(frame < (int)frames.len());
	assert(parent >= 0);
	assert(parent < frame);
	assert(frames[frame].parent == parent);
	frames[frame].next_sibling = frames[parent].first_child;
	frames[parent].first_child = frame;
}

fn void op_cav(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[3] buf;
	if (!split_ops_exact(rest, 2, line, "cav", &buf)) return;
	String name   = buf[0];
	String parent = buf[1];
	if (!check_name(name, line)) return;
	int pf = find_frame(parent, cur_proc);
	if (pf < 0) {
		viol(line, "I1", cat({ "unknown parent frame ", parent }));
		return;
	}
	if (!frames[pf].alive) {
		viol(line, "I1", cat({ "enter under dead frame ", parent }));
		return;
	}
	if (!check_dup(name, line, 0)) return;
	// Рамка proc живёт в другом scope, но делит host API с новой рамкой.
	if (find_proc(name) >= 0) {
		viol(line, "DUP", cat({ "frame shadows procedure ", name }));
		return;
	}
	// Рамки глобальны, включая созданные в proc.
	if (at_capacity(frames.len(), line, "frames")) return;
	Frame f = { .name = name, .parent = pf, .first_child = -1,
		.next_sibling = -1, .line = line, .name_column = source_column(name), .alive = true,
		.gen = nextgen(), .cname = cname_for("f_", name),
		.scope = 0, .cap = 64 };
	frames.push(f);
	int fi = (int)frames.len() - 1;
	link_frame(fi, pf);
	frame_map.set(name, fi);
	add_instr({ .op = Op.CAV, .line = line, .x = fi, .y = pf });
}

fn void op_res(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[3] buf;
	if (!split_ops_exact(rest, 3, line, "res", &buf)) return;
	String name  = buf[0];
	String fname = buf[1];
	String ssize = buf[2];
	if (!check_name(name, line)) return;
	int size          = -1;
	int layout        = -1;
	int element_count =  0;
	if (is_int(ssize)) {
		int? sv = ssize.to_int();
		if (catch sv) {
			viol(line, "STRUCT", cat({ "bad size ", ssize, " (want positive int)" }));
			return;
		}
		size = sv;
		if (size <= 0) {
			viol(line, "STRUCT", cat({ "bad size ", ssize, " (want positive int)" }));
			return;
		}
	} else if (!parse_layout_use(ssize, line, &layout, &element_count, &size)) {
		return;
	}
	int f = find_frame(fname, cur_proc);
	if (f < 0) {
		viol(line, "I1", cat({ "cell in unknown frame ", name, " ", fname }));
		return;
	}
	if (!frames[f].alive) {
		viol(line, "I1", cat({ "cell in dead frame ", name, " ", fname }));
		return;
	}
	if (size > CELL_SIZE_BYTES_MAX) {
		viol(line, "STRUCT", "aligned cell size out of i32 range");
		return;
	}
	int aligned = (size + 15) & ~15;
	if (frames[f].res_bytes > 2147483647 - aligned) {
		viol(line, "STRUCT", cat({ "frame capacity out of i32 range: ", fname }));
		return;
	}
	if (!check_dup(name, line, 0)) return;
	if (at_capacity(cells.len(), line, "cells")) return;
	Cell cc = {
		.name = name,
		.line = line,
		.name_column = source_column(name),
		.owner = f,
		.home = f,
		.size = size,
		.cname = cname_for("c_", name),
		.scope = 0,
		.layout = layout,
		.element_count = element_count
	};
	cells.push(cc);
	cell_map.set(name, (int)cells.len() - 1);
	frames[f].res_bytes += aligned;
	add_instr({ .op = Op.RES, .line = line, .x = (int)cells.len() - 1, .y = f, .a = size });
}

fn void op_med(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	if (cur_proc > 0 && procs[(sz)(cur_proc - 1)].contracted) {
		viol(line, "STRUCT", "mediator declaration in contracted proc");
		return;
	}
	String[3] buf;
	if (!split_ops_exact(rest, 3, line, "med", &buf)) return;
	String name   = buf[0];
	String cn     = buf[1];
	String issuer = buf[2];
	if (!check_name(name, line)) return;
	if (!name.ends_with("_m")) {
		viol(line, "STRUCT", cat({ "mediator name ", name, " must end with _m" }));
		return;
	}
	int ci = find_cell(cn, cur_proc);
	if (ci < 0) {
		viol(line, "I2", cat({ "link to unknown cell ", name, " ", cn }));
		return;
	}
	int is = find_frame(issuer, cur_proc);
	if (is < 0) {
		viol(line, "I2", cat({ "unknown issuer frame ", issuer }));
		return;
	}
	if (!is_ancestor(cells[ci].owner, is, false)) {
		viol(line, "I2", cat({ "link issued by non-owner non-ancestor ", issuer, " ", cn }));
		return;
	}
	if (!check_dup(name, line, cur_proc)) return;
	// Host API экспортирует каждый медиатор: имя глобально уникально.
	if (med_map.has_key(name)) {
		viol(line, "DUP", cat({ "duplicate mediator ", name }));
		return;
	}
	if (at_capacity(meds.len(), line, "mediators")) return;
	if (cells[ci].med_count >= CELL_MED_MAX) {
		viol(line, "STRUCT", "too many mediators for one cell");
		return;
	}
	Med m = {
		.name = name,
		.line = line,
		.name_column = source_column(name),
		.cell = ci,
		.owner = cells[ci].owner,
		.issuer = is,
		.gen = frames[cells[ci].owner].gen,
		.home_gen = frames[cells[ci].home].gen,
		.cname = cname_for("m_", name),
		.scope = cur_proc,
		.view_source = -1,
		.cascade = -1,
		.extent = cells[ci].layout >= 0 ? cells[ci].element_count : cells[ci].size
	};
	meds.push(m);
	int mi = (int)meds.len() - 1;
	med_map.set(name, mi);
	cells[ci].med_idxs[cells[ci].med_count] = mi;
	cells[ci].med_count++;
	add_instr({ .op = Op.MED, .line = line, .x = mi });
}

fn bool parse_view_operand(String text, int line, ViewOperand* operand) {
	*operand = { .reg = -1 };
	if (is_int(text)) {
		operand.operand_kind = OperandKind.IMMEDIATE;
		return parse_i64(text, line, &operand.immediate);
	}
	if (text.len > 0 && text[0] == '%') {
		operand.operand_kind = OperandKind.REGISTER;
		operand.reg = parse_reg(text, line);
		return operand.reg >= 0;
	}
	viol(line, "STRUCT", cat({ "bad view operand ", text, " (want i64 or register)" }));
	return false;
}

fn bool view_range_valid(int source, String name, ViewOperand offset,
		ViewOperand length, int line) {
	int ci = meds[source].cell;
	int max = cells[ci].layout >= 0 ? cells[ci].element_count : cells[ci].size;
	bool offset_immediate = offset.operand_kind == OperandKind.IMMEDIATE;
	bool length_immediate = length.operand_kind == OperandKind.IMMEDIATE;
	long offset_value = immediate_i64(offset.immediate);
	long length_value = immediate_i64(length.immediate);
	if (offset_immediate && (offset_value < 0 || offset_value > max)) {
		viol(line, "STRUCT", cat({ "view range out of bounds ", name }));
		return false;
	}
	if (length_immediate && (length_value < 0 || length_value > max)) {
		viol(line, "STRUCT", cat({ "view range out of bounds ", name }));
		return false;
	}
	if (meds[source].extent < 0 || !offset_immediate || !length_immediate) return true;
	if (offset_value > meds[source].extent
			|| length_value > meds[source].extent - offset_value) {
		viol(line, "STRUCT", cat({ "view range out of bounds ", name }));
		return false;
	}
	return true;
}

fn int resolve_view_source(String name, int line) {
	int source = find_med(name, cur_proc);
	if (source == -2) {
		scope_viol(line, "mediator", name);
		return -1;
	}
	if (source < 0) {
		viol(line, "STRUCT", cat({ "view via unknown mediator ", name }));
		return -1;
	}
	if (!med_visible_here(source)) {
		cascade_scope_viol(line, name);
		return -1;
	}
	if (cur_casc >= 0 && !cascade_input_ok(name)) {
		viol(line, "STRUCT", cat({ "cascade body addresses non-input mediator ", name }));
		return -1;
	}
	if (!check_proc_med_access(source, line, "view", false)) return -1;
	return source;
}

fn void op_view(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[4] buf;
	if (!split_ops_exact(rest, 4, line, "view", &buf)) return;
	String name = buf[0];
	if (!check_name(name, line)) return;
	if (!name.ends_with("_m")) {
		viol(line, "STRUCT", cat({ "mediator name ", name, " must end with _m" }));
		return;
	}
	int source = resolve_view_source(buf[1], line);
	if (source < 0) return;
	ViewOperand offset;
	ViewOperand length;
	if (!parse_view_operand(buf[2], line, &offset)) return;
	if (!parse_view_operand(buf[3], line, &length)) return;
	if (!view_range_valid(source, name, offset, length, line)) return;
	if (!check_dup(name, line, cur_proc)) return;
	if (med_map.has_key(name)) {
		viol(line, "DUP", cat({ "duplicate mediator ", name }));
		return;
	}
	if (at_capacity(meds.len(), line, "mediators")) return;
	int ci = meds[source].cell;
	if (cells[ci].med_count >= CELL_MED_MAX) {
		viol(line, "STRUCT", "too many mediators for one cell");
		return;
	}
	Med m = {
		.name = name, .line = line, .name_column = source_column(name),
		.cell = ci, .owner = meds[source].owner, .issuer = meds[source].issuer,
		.gen = meds[source].gen, .home_gen = meds[source].home_gen,
		.cname = cname_for("m_", name), .scope = cur_proc,
		.cascade = cur_casc,
		.read_only = proc_med_access(source, cur_proc) == 0,
		.view_source = source, .view_offset = offset, .view_length = length,
		.extent = length.operand_kind == OperandKind.IMMEDIATE
			? (int)immediate_i64(length.immediate) : -1
	};
	meds.push(m);
	int mi = (int)meds.len() - 1;
	med_map.set(name, mi);
	cells[ci].med_idxs[cells[ci].med_count] = mi;
	cells[ci].med_count++;
	add_instr({ .op = Op.VIEW, .line = line, .x = mi });
}

fn void op_raise(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[2] buf;
	if (!split_ops_exact(rest, 2, line, "raise", &buf)) return;
	String cn    = buf[0];
	String fname = buf[1];
	int ci       = find_cell(cn, cur_proc);
	if (ci < 0) {
		viol(line, "I4", cat({ "raise of unknown cell ", cn }));
		return;
	}
	int f = find_frame(fname, cur_proc);
	if (f < 0) {
		viol(line, "I4", cat({ "raise to unknown frame ", fname }));
		return;
	}
	if (!is_ancestor(cells[ci].owner, f, true)) {
		viol(
			line,
			"I4",
			cat({ "raise to non-ancestor (sideways/down forbidden) ", cn, " ", fname })
		);
		return;
	}
	if (!frames[f].alive) {
		viol(line, "I4", cat({ "raise into dead frame ", cn, " ", fname }));
		return;
	}
	if (!frames[cells[ci].owner].alive) {
		viol(
			line,
			"I4",
			cat({ "raise of cell in dead frame ", cn, " ", frames[cells[ci].owner].name })
		);
		return;
	}
	cells[ci].owner = f; // Новые медиаторы используют нового владельца.
	add_instr({ .op = Op.RAISE, .line = line, .x = ci, .y = f });
}

fn void op_decay(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[1] buf;
	if (!split_ops_exact(rest, 1, line, "decay", &buf)) return;
	String fname = buf[0];
	int f        = find_frame(fname, cur_proc);
	if (f < 0) {
		viol(line, "DECAY", cat({ "leave of unknown frame ", fname }));
		return;
	}
	if (frames[f].is_field) {
		viol(line, "DECAY", cat({ "leave of root (field) forbidden ", fname }));
		return;
	}
	if (cur_proc > 0 && f == procs[(sz)(cur_proc - 1)].frame) {
		viol(line, "DECAY", cat({ "leave of procedure frame ", fname, " (use ret)" }));
		return;
	}
	if (!frames[f].alive) {
		viol(line, "DECAY", cat({ "double leave ", fname }));
		return;
	}
	kill(f);
	add_instr({ .op = Op.DECAY, .line = line, .x = f });
}

fn void op_probe(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[1] buf;
	if (!split_ops_exact(rest, 1, line, "probe", &buf)) return;
	String mname = buf[0];
	int mi       = find_med(mname, cur_proc);
	if (mi == -2) {
		scope_viol(line, "mediator", mname);
		return;
	}
	if (mi < 0) {
		viol(line, "STRUCT", cat({ "probe of unknown mediator ", mname }));
		return;
	}
	if (!med_visible_here(mi)) {
		cascade_scope_viol(line, mname);
		return;
	}
	if (!check_proc_med_access(mi, line, "probe", false)) return;
	add_instr({ .op = Op.PROBE, .line = line, .x = mi });
}

// --- память через медиатор -------------------------------------------------------
// разбор "[med + off]" или "[med + index].field"
fn bool parse_mem(String tok, int line, String* mname, int* off, int* off_reg, String* field_name) {
	String t = tok.trim();
	*off = 0;
	*off_reg = -1;
	*field_name = "";
	bool bad  = t.len < 5 || t[0] != '[';
	sz? close = t.index_of_char(']');
	if (catch close) {
		viol(
			line,
			"STRUCT",
			cat({ "bad memory operand ", tok, " (want [med + off] or [med + index].field)" })
		);
		return false;
	}
	if (!bad) {
		String suffix = t[close + 1..].trim();
		if (suffix.len > 0) {
			if (suffix[0] != '.' || !is_name(suffix[1..])) {
				bad = true;
			} else {
				*field_name = suffix[1..];
			}
		}
	}
	if (!bad) {
		String inner = t[1..close - 1];
		sz? plus     = inner.index_of_char('+');
		if (catch plus) {
			bad = true;
		} else {
			*mname = inner[:plus].trim();
			String offset = inner[plus + 1..].trim();
			if (!is_name(*mname)) {
				bad = true;
			} else if (is_int(offset)) {
				int? value = offset.to_int();
				if (catch value) {
					viol(line, "STRUCT", cat({ "mem offset out of i32 range: ", offset }));
					return false;
				}
				*off = value;
			} else if (offset.len > 0 && offset[0] == '%') {
				int reg = parse_reg(offset, line);
				if (reg < 0) {
					bad = true;
				} else {
					*off_reg = reg;
				}
			} else {
				bad = true;
			}
		}
	}
	if (bad) {
		viol(
			line,
			"STRUCT",
			cat({ "bad memory operand ", tok, " (want [med + off] or [med + index].field)" })
		);
		return false;
	}
	return true;
}

fn bool cascade_input_ok(String mname) {
	if (cur_casc < 0) return true;
	int? found = med_map.get(mname);
	if (try mi = found) {
		if (meds[mi].cascade == cur_casc) return true;
	}
	foreach (name : cascades[cur_casc].med_names[:cascades[cur_casc].med_count]) {
		if (name == mname) return true;
	}
	return false;
}

// разрешение медиатора для load/store; -1 = ошибка (violation записано)
fn int resolve_mem_med(
	String tok,
	int line,
	OpDesc* desc,
	int* off,
	int* off_reg,
	int* field_index
) {
	String mname;
	String field_name;
	assert(desc != null && desc.has_scalar_type);
	String opname = desc.source_name;
	*field_index = -1;
	if (!parse_mem(tok, line, &mname, off, off_reg, &field_name)) return -1;
	int mi = find_med(mname, cur_proc);
	if (mi == -2) {
		scope_viol(line, "mediator", mname);
		return -1;
	}
	if (mi < 0) {
		viol(line, "STRUCT", cat({ opname, " via unknown mediator ", mname }));
		return -1;
	}
	if (!med_visible_here(mi)) {
		cascade_scope_viol(line, mname);
		return -1;
	}
	if (!check_proc_med_access(mi, line, opname, desc.write)) return -1;
	int ci = meds[mi].cell;
	if (cells[ci].layout >= 0) {
		if (!check_typed_access(
			mi,
			field_name,
			desc,
			*off,
			*off_reg,
			line,
			field_index
		)) return -1;
	} else {
		if (field_name.len > 0) {
			viol(line, "STRUCT", "field access requires typed cell");
			return -1;
		}
		int width = scalar_width(desc.scalar_type);
		int size  = meds[mi].extent;
		bool fixed_bad = *off >= 0 && size >= 0 && (*off > size || width > size - *off);
		if (*off_reg < 0 && (*off < 0 || fixed_bad)) {
			viol(line, "STRUCT", cat({ opname, " out of bounds via ", mname }));
			return -1;
		}
	}
	if (!cascade_input_ok(mname)) {
		viol(line, "STRUCT", cat({ "cascade body addresses non-input mediator ", mname }));
		return -1;
	}
	return mi;
}

fn void op_load2(String rest, int line, OpDesc* desc) {
	String[2] buf;
	if (!split_ops_exact(rest, 2, line, desc.source_name, &buf)) return;
	int dst     = parse_reg(buf[0], line);
	int off     = 0;
	int off_reg = -1;
	int field   = -1;
	int mi      = resolve_mem_med(buf[1], line, desc, &off, &off_reg, &field);
	if (dst < 0 || mi < 0) return;
	add_instr(
		{
			.op = Op.LOAD,
			.line = line,
			.a = dst,
			.x = mi,
			.y = field,
			.b = off,
			.c = off_reg,
			.scalar_type = desc.scalar_type
		}
	);
}

fn void op_store2(String rest, int line, OpDesc* desc) {
	String[2] buf;
	if (!split_ops_exact(rest, 2, line, desc.source_name, &buf)) return;
	int off     = 0;
	int off_reg = -1;
	int field   = -1;
	int mi      = resolve_mem_med(buf[0], line, desc, &off, &off_reg, &field);
	int src     = parse_reg(buf[1], line);
	if (mi < 0 || src < 0) return;
	add_instr(
		{
			.op = Op.STORE,
			.line = line,
			.a = src,
			.x = mi,
			.y = field,
			.b = off,
			.c = off_reg,
			.scalar_type = desc.scalar_type
		}
	);
}

// --- данные и поток ----------------------------------------------------------------
fn void op_mov(String rest, int line, OpDesc* desc) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[2] buf;
	if (!split_ops_exact(rest, 2, line, desc.source_name, &buf)) return;
	int dst = parse_reg(buf[0], line);
	if (dst < 0) return;
	if (is_int(buf[1])) {
		Immediate value;
		bool valid = desc.typed
			? parse_typed_immediate(buf[1], desc.scalar_type, line, &value)
			: parse_i64(buf[1], line, &value);
		if (!valid) return;
		add_instr({
			.op = Op.MOV,
			.line = line,
			.a = dst,
			.immediate = value,
			.operand_kind = OperandKind.IMMEDIATE,
			.scalar_type = desc.scalar_type
		});
		return;
	}
	int src = parse_reg(buf[1], line);
	if (src < 0) return;
	add_instr({
		.op = Op.MOV,
		.line = line,
		.a = dst,
		.b = src,
		.operand_kind = OperandKind.REGISTER,
		.scalar_type = desc.scalar_type
	});
}

fn void op_alu3(String rest, int line, OpDesc* desc) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[3] buf;
	if (!split_ops_exact(rest, 3, line, desc.source_name, &buf)) return;
	int d = parse_reg(buf[0], line);
	int a = parse_reg(buf[1], line);
	if (d < 0 || a < 0) return;
	if (is_int(buf[2])) {
		Immediate value;
		bool shift_count = desc.alu_op == AluOp.SHL || desc.alu_op == AluOp.SHR ||
			desc.alu_op == AluOp.USHR;
		bool valid = desc.typed && !shift_count
			? parse_typed_immediate(buf[2], desc.scalar_type, line, &value)
			: parse_i64(buf[2], line, &value);
		if (!valid) return;
		add_instr({
			.op = Op.ALU3,
			.line = line,
			.a = d,
			.b = a,
			.immediate = value,
			.alu_op = desc.alu_op,
			.operand_kind = OperandKind.IMMEDIATE,
			.scalar_type = desc.scalar_type
		});
		return;
	}
	int b = parse_reg(buf[2], line);
	if (b < 0) return;
	add_instr({
		.op = Op.ALU3,
		.line = line,
		.a = d,
		.b = a,
		.c = b,
		.alu_op = desc.alu_op,
		.operand_kind = OperandKind.REGISTER,
		.scalar_type = desc.scalar_type
	});
}

fn void op_alu1(String rest, int line, OpDesc* desc) {
	String[1] buf;
	if (!split_ops_exact(rest, 1, line, desc.source_name, &buf)) return;
	int r = parse_reg(buf[0], line);
	if (r < 0) return;
	bool is_inc = desc.alu_op == AluOp.INC || desc.alu_op == AluOp.CINC;
	bool checked = desc.alu_op == AluOp.CINC || desc.alu_op == AluOp.CDEC;
	if (checked) {
		add_instr({
			.op = Op.ALU3,
			.line = line,
			.a = r,
			.b = r,
			.immediate = immediate_from_i64(1),
			.alu_op = is_inc ? AluOp.CADD : AluOp.CSUB,
			.operand_kind = OperandKind.IMMEDIATE,
			.scalar_type = desc.scalar_type
		});
		return;
	}
	add_instr({
		.op = Op.ALU1,
		.line = line,
		.a = r,
		.alu_op = desc.alu_op,
		.scalar_type = desc.scalar_type
	});
}

fn void op_print(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[1] buf;
	if (!split_ops_exact(rest, 1, line, "print", &buf)) return;
	int r = parse_reg(buf[0], line);
	if (r < 0) return;
	add_instr({ .op = Op.PRINT, .line = line, .a = r });
}

fn void op_await(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String[1] buf;
	if (!split_ops_exact(rest, 1, line, "await", &buf)) return;
	int r = parse_reg(buf[0], line);
	if (r < 0) return;
	add_instr({ .op = Op.AWAIT, .line = line, .a = r });
}

fn void op_jmp(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String tgt = rest.trim();
	if (!check_name(tgt, line)) return;
	add_instr({ .op = Op.JMP, .line = line, .s1 = tgt });
}

fn void op_br(String rest, int line, bool is_brz) {
	String[2] buf;
	if (!split_ops_exact(rest, 2, line, is_brz ? "brz" : "brnz", &buf)) return;
	int r = parse_reg(buf[0], line);
	if (r < 0) return;
	if (!check_name(buf[1], line)) return;
	add_instr({ .op = is_brz ? Op.BRZ : Op.BRNZ, .line = line, .a = r, .s1 = buf[1] });
}

fn bool check_proc_call(int caller_index, int callee_index, int line) {
	if (caller_index <= 0) return true;
	Proc* caller = &procs[(sz)(caller_index - 1)];
	if (!caller.contracted) return true;
	Proc* callee = &procs[(sz)callee_index];
	if (!callee.contracted) {
		viol(line, "STRUCT", cat({
			"proc ", caller.name, ": call to uncontracted proc ", callee.name,
		}));
		return false;
	}
	for (sz i = 0; i < callee.med_count; i++) {
		int mi = callee.med_idxs[i];
		int access = proc_med_access(mi, caller_index);
		if (access < 0) {
			viol(line, "STRUCT", cat({
				"proc ", caller.name, ": call uses unlisted mediator ", meds[mi].name,
				" (callee ", callee.name, ")",
			}));
			return false;
		}
		if (callee.med_write[i] && access == 0) {
			viol(line, "STRUCT", cat({
				"proc ", caller.name, ": call requires rw access to ", meds[mi].name,
				" (callee ", callee.name, ")",
			}));
			return false;
		}
	}
	return true;
}

fn void op_call(String rest, int line) {
	assert(line > 0);
	assert(rest.len <= SOURCE_BYTES_MAX);
	String name = rest.trim();
	if (!check_name(name, line)) return;
	if (cur_proc > 0 && name == procs[(usz)(cur_proc - 1)].name) {
		viol(
			line,
			"STRUCT",
			cat({ "recursive call of ", name, " (frame_reset frees the live arena)" })
		);
		return;
	}
	int pi = find_proc(name);
	if (pi < 0) {
		viol(line, "STRUCT", cat({ "call of unknown procedure ", name }));
		return;
	}
	if (!check_proc_call(cur_proc, pi, line)) return;
	procs[pi].called = true;
	add_instr({ .op = Op.CALL, .line = line, .x = pi });
}

fn int proc_med_access(int mi, int func) {
	if (func <= 0) return 1;
	Proc* p = &procs[(sz)(func - 1)];
	if (!p.contracted) return 1;
	if (meds[mi].view_source >= 0 && meds[mi].scope == func) {
		return meds[mi].read_only ? 0 : 1;
	}
	for (sz i = 0; i < p.med_count; i++) {
		if (p.med_idxs[i] == mi) return p.med_write[i] ? 1 : 0;
	}
	return -1;
}

fn bool check_proc_med_access(int mi, int line, String opname, bool write) {
	int access = proc_med_access(mi, cur_proc);
	if (access >= 0 && (!write || access > 0)) return true;
	String kind = access < 0 ? "unlisted" : "read-only";
	String proc_name = procs[(sz)(cur_proc - 1)].name;
	viol(line, "STRUCT", cat({
		"proc ", proc_name, ": ", opname, " via ", kind, " mediator ", meds[mi].name,
	}));
	return false;
}

fn void add_proc_capability(Proc* p, String item, int line) {
	String token = item.trim();
	sz? separator = token.index_of_char(':');
	if (catch separator) {
		viol(line, "STRUCT", "malformed proc contract entry");
		return;
	}
	String name = token[:separator].trim();
	String capability = token[separator + 1..].trim();
	if (capability != "ro" && capability != "rw") {
		viol(line, "STRUCT", cat({ "invalid contract capability ", capability }));
		return;
	}
	if (!check_name(name, line)) return;
	int mi = find_med(name, 0);
	if (mi < 0) {
		viol(line, "STRUCT", cat({ "unknown contract mediator ", name }));
		return;
	}
	for (sz i = 0; i < p.med_count; i++) {
		if (p.med_idxs[i] == mi) {
			viol(line, "DUP", cat({ "duplicate contract mediator ", name }));
			return;
		}
	}
	if (p.med_count >= CASC_MED_MAX) {
		viol(line, "STRUCT", "proc contract capacity exceeded");
		return;
	}
	p.med_idxs[p.med_count] = mi;
	p.med_write[p.med_count] = capability == "rw";
	p.med_count++;
}

fn void parse_proc_contract(Proc* p, String entries, int line) {
	String rest = entries.trim();
	while (rest.len > 0) {
		sz? comma = rest.index_of_char(',');
		if (catch comma) {
			add_proc_capability(p, rest, line);
			return;
		}
		add_proc_capability(p, rest[:comma], line);
		rest = rest[comma + 1..];
		if (rest.trim().len == 0) add_proc_capability(p, rest, line);
	}
}

// --- proc / casc ---------------------------------------------------------------------
fn void open_proc(String name, int line) {
	if (find_proc(name) >= 0) {
		viol(line, "DUP", cat({ "duplicate procedure ", name }));
		return;
	}
	if (host_name_bad(name, line)) return;
	if (find_frame(name, 0) >= 0 || cur_proc > 0 && find_frame(name, cur_proc) >= 0) {
		viol(line, "DUP", cat({ "procedure shadows frame ", name }));
		return;
	}
	if (at_capacity(frames.len(), line, "frames")) return;
	if (at_capacity(procs.len(), line, "procedures")) return;
	if (at_capacity(blocks.len(), line, "blocks")) return;
	blocks.push({ .kind = 1, .aux = (int)procs.len() });
	Frame f = { .name = name, .parent = 0, .first_child = -1,
		.next_sibling = -1, .line = line, .name_column = source_column(name), .alive = true,
		.gen = nextgen(), .cname = cat({ "f_P_", name }),
		.scope = (int)procs.len() + 1, .cap = 64, .is_procframe = true };
	frames.push(f);
	int fi = (int)frames.len() - 1;
	link_frame(fi, 0);
	frame_map.set(name, fi);
	Proc p = {
		.name = name,
		.line = line,
		.name_column = source_column(name),
		.frame = fi,
		.block = (int)blocks.len() - 1,
		.cname = cat({ "p_", name })
	};
	procs.push(p);
	proc_map.set(name, (int)procs.len() - 1);
	cur_proc = (int)procs.len(); // 1-based
}

fn void do_ret(int line) {
	if (cur_proc > 0) {
		add_instr({ .op = Op.RET, .line = line });
		// Чекер и runtime разрушают рамку proc и её поддерево.
		procs[(sz)(cur_proc - 1)].end_line = line;
		kill(procs[(sz)(cur_proc - 1)].frame);
		cur_proc = 0;
		return;
	}
	add_instr({ .op = Op.RET, .line = line });
	if (top_ret == 0) top_ret = line;
}

fn bool parse_casc_header(
	String rest,
	int line,
	bool is_async,
	String* name,
	String* medstr,
	String* outname,
	String* outfname
) {
	sz? ci = rest.index_of_char(':');
	if (catch ci) {
		viol(line, "STRUCT", "malformed cascade header");
		return false;
	}
	*name = rest[:ci].trim();
	String r2 = rest[ci + 1..];
	sz? ai    = r2.index_of("->");
	if (catch ai) {
		viol(line, "STRUCT", "malformed cascade header");
		return false;
	}
	*medstr = r2[:ai].trim();
	String outstr = r2[ai + 2..].trim();
	*outname = outstr;
	*outfname = "";
	sz? bi = outstr.index_of_char('[');
	if (try bi) {
		sz? ei = outstr.index_of_char(']');
		if (catch ei) {
			viol(line, "STRUCT", "malformed cascade header");
			return false;
		}
		if (ei <= bi + 1 || ei != outstr.len - 1) {
			viol(line, "STRUCT", "malformed cascade header");
			return false;
		}
		*outname = outstr[:bi].trim();
		*outfname = outstr[bi + 1..ei - 1].trim();
	}
	if (!is_async && outfname.len == 0) {
		viol(line, "STRUCT", "sync cascade out frame is required");
		return false;
	}
	if (is_async && outfname.len > 0) {
		viol(line, "STRUCT", "acasc out frame is implicit (always field)");
		return false;
	}
	return true;
}

fn void add_casc_input(
	String tok,
	int line,
	String name,
	bool is_async,
	int[] med_idxs,
	String[] med_names,
	int* count
) {
	if (tok.len == 0 || !check_name(tok, line)) return;
	int mdi = find_med(tok, cur_proc);
	if (mdi == -2) {
		scope_viol(line, "mediator", tok);
		return;
	}
	if (mdi < 0) {
		viol(line, "I3", cat({ "cascade uses unknown link ", name, " ", tok }));
		return;
	}
	if (!med_visible_here(mdi)) {
		cascade_scope_viol(line, tok);
		return;
	}
	if (!check_proc_med_access(mdi, line, "cascade", false)) return;
	if (*count >= CASC_MED_MAX) {
		viol(line, "STRUCT", "too many cascade inputs");
		return;
	}
	foreach (prev : med_names[:(*count)]) {
		if (prev == meds[mdi].name) {
			viol(line, "DUP", cat({ "cascade ", name, ": duplicate input link ", tok }));
		}
	}
	med_idxs[*count] = mdi;
	med_names[*count] = meds[mdi].name;
	(*count)++;
	if (is_async) {
		if (!frames[cells[meds[mdi].cell].owner].is_field
			|| !frames[cells[meds[mdi].cell].home].is_field) {
			viol(line, "I3", cat({ "async cascade holds non-root link ", name, " ", tok }));
		}
	} else if (!med_alive(mdi)) {
		viol(line, "I3", cat({ "sync cascade aborted: dead link on entry ", name, " ", tok }));
	}
}

fn int open_casc_out(String outname, String outfname, bool is_async, int line, int* out_frame) {
	if (!check_name(outname, line) || !check_dup(outname, line, 0)) return -1;
	*out_frame = is_async ? 0 : find_frame(outfname, cur_proc);
	if (*out_frame < 0) {
		viol(line, "I3", cat({ "out cell in unknown frame ", outname, " ", outfname }));
		return -1;
	}
	if (!frames[*out_frame].alive) {
		viol(line, "I1", cat({ "cell in dead frame ", outname, " ", frames[*out_frame].name }));
	}
	if (at_capacity(cells.len(), line, "cells")) return -1;
	Cell oc = { .name = outname, .line = line, .name_column = source_column(outname),
		.owner = *out_frame, .home = *out_frame,
		.size = 8, .cname = cname_for("c_", outname), .scope = 0,
		.async_out = is_async, .layout = -1, .element_count = 0 };
	cells.push(oc);
	cell_map.set(outname, (int)cells.len() - 1);
	frames[*out_frame].outs += 1;
	return (int)cells.len() - 1;
}

fn void open_casc(String rest, int line, bool is_async) {
	String name, medstr, outname, outfname;
	if (!parse_casc_header(rest, line, is_async, &name, &medstr, &outname, &outfname)) return;
	if (!check_name(name, line)) return;
	if (at_capacity(cascades.len(), line, "cascades")) return;
	if (at_capacity(blocks.len(), line, "blocks")) return;
	int[CASC_MED_MAX] med_idxs;
	String[CASC_MED_MAX] med_names;
	int count = 0;
	if (medstr.len == 0) {
		viol(line, "STRUCT", cat({ "cascade ", name, " without input mediators" }));
	}
	String ms = medstr;
	while (ms.len > 0) {
		sz? mi2 = ms.index_of_char(',');
		String tok;
		if (catch mi2) {
			tok = ms.trim();
			ms = "";
		} else {
			tok = ms[:mi2].trim();
			ms = ms[mi2 + 1..];
		}
		add_casc_input(tok, line, name, is_async, med_idxs[..], med_names[..], &count);
	}
	int out_frame = -1;
	int out_cell  =  open_casc_out(outname, outfname, is_async, line, &out_frame);
	casc_seq++;
	blocks.push({ .kind = 2, .aux = casc_seq });
	Cascade ca = {
		.name = name,
		.line = line,
		.seq = casc_seq,
		.is_async = is_async,
		.block = (int)blocks.len() - 1,
		.med_idxs = med_idxs,
		.med_names = med_names,
		.med_count = count,
		.out_cell = out_cell,
		.out_frame = out_frame
	};
	cascades.push(ca);
	cur_casc = (int)cascades.len() - 1;
	if (at_capacity(instrs.len(), line, "instructions")) return;
	Instr ins = { .op = Op.CASC, .line = line, .a = cur_casc };
	ins.func = cur_func();
	ins.block = cur_proc > 0 ? procs[(sz)(cur_proc - 1)].block : 0;
	instrs.push(ins);
}

fn void end_casc(int line) {
	Instr ins = { .op = Op.ENDC, .line = line, .a = cur_casc };
	ins.func = cur_func();
	ins.block = (cur_proc > 0) ? procs[(sz)(cur_proc - 1)].block : 0;
	if (!at_capacity(instrs.len(), line, "instructions")) instrs.push(ins);
	cur_casc = -1;
}

// --- диспетчер инструкций -------------------------------------------------------------
fn void cascade_op_viol(String op, int n) {
	String kind = cascades[cur_casc].is_async ? "async cascade body" : "cascade body";
	viol(
		n,
		"STRUCT",
		cat({ "op ", op, " not allowed in ", kind, " (data instructions only)" })
	);
}

fn void parse_instr(String line, int n, bool in_casc) {
	sz sp = (sz)line.len;
	for (sz i = 0; i < line.len; i++) {
		if (line[i] == ' ' || line[i] == '\t') {
			sp = i;
			break;
		}
	}
	String op   = line[:sp];
	String rest = (sp < line.len) ? line[sp + 1..].trim() : "";
	OpDesc resolved;
	if (!resolve_op_desc(op, &resolved)) {
		if (in_casc) {
			cascade_op_viol(op, n);
		} else {
			viol(n, "STRUCT", cat({ "unknown op ", op }));
		}
		return;
	}
	OpDesc* desc = &resolved;
	if (in_casc && !op_desc_cascade_ok(desc, cascades[cur_casc].is_async)) {
		cascade_op_viol(op, n);
		return;
	}
	switch (desc.op) {
		case Op.CAV: op_cav(rest, n);
		case Op.LAYOUT: op_layout(rest, n);
		case Op.RES: op_res(rest, n);
		case Op.MED: op_med(rest, n);
		case Op.VIEW: op_view(rest, n);
		case Op.RAISE: op_raise(rest, n);
		case Op.DECAY: op_decay(rest, n);
		case Op.PROBE: op_probe(rest, n);
		case Op.LOAD: op_load2(rest, n, desc);
		case Op.STORE: op_store2(rest, n, desc);
		case Op.MOV: op_mov(rest, n, desc);
		case Op.ALU3: op_alu3(rest, n, desc);
		case Op.ALU1: op_alu1(rest, n, desc);
		case Op.PRINT: op_print(rest, n);
		case Op.JMP: op_jmp(rest, n);
		case Op.BRZ: op_br(rest, n, true);
		case Op.BRNZ: op_br(rest, n, false);
		case Op.CALL: op_call(rest, n);
		case Op.AWAIT: op_await(rest, n);
		default: unreachable("unexpected source opcode");
	}
}

// --- главный цикл разбора -----------------------------------------------------------------
fn void open_proc_line(String line, int n, int sp) {
	if (cur_proc > 0) {
		viol(n, "STRUCT", cat({ "nested proc ", line[sp..].trim() }));
		return;
	}
	String header = line[sp..].trim();
	if (header.len <= 1 || header[header.len - 1] != ':') {
		viol(n, "STRUCT", "malformed proc header");
		return;
	}
	header = header[:header.len - 1].trim();
	sz? opening = header.index_of_char('(');
	if (catch opening) {
		if (!is_name(header)) {
			viol(n, "STRUCT", "malformed proc header");
			return;
		}
		open_proc(header, n);
		return;
	}
	sz closing = header.len - 1;
	if (header.len < 2 || header[closing] != ')') {
		viol(n, "STRUCT", "malformed proc contract");
		return;
	}
	String name = header[:opening].trim();
	if (!is_name(name)) {
		viol(n, "STRUCT", "malformed proc contract");
		return;
	}
	sz before = procs.len();
	open_proc(name, n);
	if (procs.len() == before) return;
	Proc* p = &procs[before];
	p.contracted = true;
	if (closing > opening + 1) {
		parse_proc_contract(p, header[opening + 1..closing - 1], n);
	}
}

fn void run(String text) {
	source_hash = sha256::hash(text);
	String[] lines = text.split(workmem, "\n");
	for (sz i = 0; i < lines.len; i++) {
		int n      = (int)i + 1;
		String raw = lines[i];
		source_line_raw = raw;
		sz? sci     = raw.index_of_char(';');
		String line = raw.trim();
		if (try sci) line = raw[:sci].trim();
		if (line.len == 0) continue;
		// код после верхнеуровневого ret — violation (каждая строка)
		if (cur_proc == 0 && cur_casc < 0 && top_ret > 0) {
			viol(n, "STRUCT", "code after top-level ret");
		}
		if (cur_casc >= 0) {
			if (line == "endc") {
				end_casc(n);
				continue;
			}
			if (line.len > 1 && line[line.len - 1] == ':' && is_name(line[:line.len - 1])) {
				add_label(line[:line.len - 1], n);
				continue;
			}
			parse_instr(line, n, true);
			continue;
		}
		if (line == "endc") {
			viol(n, "STRUCT", "endc without casc");
			continue;
		}
		if (line.len > 1 && line[line.len - 1] == ':' && is_name(line[:line.len - 1])) {
			add_label(line[:line.len - 1], n);
			continue;
		}
		// служебные слова
		sz sp = (sz)line.len;
		for (sz j = 0; j < line.len; j++) {
			if (line[j] == ' ' || line[j] == '\t') {
				sp = j;
				break;
			}
		}
		String w0 = line[:sp];
		if (w0 == "proc") {
			open_proc_line(line, n, (int)sp);
			continue;
		}
		if (w0 == "casc" || w0 == "acasc") {
			open_casc(line[sp..].trim(), n, w0 == "acasc");
			continue;
		}
		if (line == "ret") {
			do_ret(n);
			continue;
		}
		parse_instr(line, n, false);
	}
	finish_run();
}

fn void finish_run() {
	if (cur_casc >= 0) {
		viol(
			cascades[cur_casc].line,
			"STRUCT",
			cat({ "unterminated cascade ", cascades[cur_casc].name, " (missing endc)" })
		);
	}
	if (cur_proc > 0) {
		viol(
			procs[(sz)(cur_proc - 1)].line,
			"STRUCT",
			cat({ "unterminated proc ", procs[(sz)(cur_proc - 1)].name, " (missing ret)" })
		);
	}
	assert(frames.len() <= NODE_MAX);
	assert(cells.len() <= NODE_MAX);
	assert(meds.len() <= NODE_MAX);
	assert(procs.len() <= NODE_MAX);
	assert(instrs.len() <= NODE_MAX);
	assert(blocks.len() > 0);
	if (violations == 0) assert(cur_casc < 0);
	if (violations == 0) assert(cur_proc == 0);
	check_jumps();
	compute_caps();
}

fn void check_jumps() {
	for (sz i = 0; i < instrs.len(); i++) {
		Instr* ins = &instrs[i];
		if (ins.op != Op.JMP && ins.op != Op.BRZ && ins.op != Op.BRNZ) continue;
		if (try li = label_map.get(label_key(ins.block, ins.s1))) {
			labels[li].referenced = true;
			continue;
		}
		if (label_names.has_key(ins.s1)) {
			viol(
				ins.line,
				"STRUCT",
				cat(
					{
						"jump to label ",
						ins.s1,
						" of another lexical block ",
						"(cross-block jumps are forbidden)"
					}
				)
			);
		} else {
			viol(ins.line, "STRUCT", cat({ "jump to unknown label ", ins.s1 }));
		}
	}
}

fn void compute_caps() {
	long total_all = 0;
	for (sz i = 0; i < frames.len(); i++) {
		long total = frames[i].res_bytes + (long)frames[i].outs * 16;
		if (total > 2147483647) {
			viol(frames[i].line, "STRUCT", "frame capacity out of i32 range");
			total = 64;
		}
		if (total > ARENA_FRAME_MAX) {
			viol(frames[i].line, "STRUCT", "frame capacity exceeds static budget");
			total = 64;
		}
		frames[i].cap = total > 64 ? (int)total : 64;
		total_all += frames[i].cap;
		if (total_all > ARENA_TOTAL_MAX) {
			viol(frames[i].line, "STRUCT", "total arena capacity exceeds static budget");
		}
	}
	assert(frames.len() > 0);
	assert(total_all >= 0);
	if (violations == 0) assert(total_all <= ARENA_TOTAL_MAX);
	for (sz i = 0; i < frames.len(); i++) {
		assert(frames[i].cap >= 64);
		assert(frames[i].cap <= ARENA_FRAME_MAX);
		assert(frames[i].res_bytes >= 0);
		assert(frames[i].outs >= 0);
		assert(frames[i].parent >= -1);
		assert(frames[i].parent < (int)i);
	}
}

// --- генерация C23 ------------------------------------------------------------------
