// REZ3-ASM (.rza) -> C23. C3 0.8.5, refs/rez3.h + refs/rez3ext.h.
// CLI: rez3asm file.rza [--emit-c | --emit-lib] [-o file.c]
//      rez3asm --lsp
// Инварианты проверяются за один проход; метки разрешаются вторым.
// Мёртвый медиатор при load/store — runtime FAULT (SPEC §3).
module rez3asm;

import std::io;
import std::io::file;
import std::core::dstring;
import std::core::mem::allocators;
import std::collections::list;

const int NODE_MAX = 16384;
const int CELL_MED_MAX = 64;
const int CASC_MED_MAX = 64;
const int SOURCE_BYTES_MAX = 1048576;
const int OUTPUT_BYTES_MAX = 67108864;
const int WORK_BYTES = 134217728;

char[WORK_BYTES] work_storage;
ArenaAllocator work_arena;
Allocator workmem;

fn void init_workmem() {
    work_arena.init(work_storage[..]);
    workmem = &work_arena;
}

// --- модель ------------------------------------------------------------------
struct Frame {
    String name;
    int    parent;        // индекс в frames, -1 = нет
    int    first_child;
    int    next_sibling;
    int    line;
    bool   alive;
    uint   gen;
    uint   decay_id;      // первый decay, убивший рамку; 0 = жива
    String cname;
    int    scope;         // 0 = global, иначе индекс proc (1-based)
    int    res_bytes;     // сумма align16(size) всех res
    int    outs;          // out-ячейки каскадов в этой рамке
    int    cap;
    bool   is_field;
    bool   is_procframe;  // рамка процедуры (by value, &f_P_x)
}

struct Cell {
    String name;
    int    owner;         // текущий владелец после raise
    int    home;          // рамка, которой принадлежит физическая память
    int    size;
    String cname;
    int    scope;
    int[CELL_MED_MAX] med_idxs;
    int    med_count;
}

struct Med {
    String name;
    int    cell;          // индекс Cell
    int    owner;         // владелец на момент объявления медиатора
    uint   gen;
    String cname;
    int    scope;
}

struct Proc {
    String name;
    int    line;
    int    frame;         // индекс Frame (рамка процедуры)
    int    block;
    String cname;
    bool   called;
}

struct Cascade {
    String name;
    int    line;
    int    seq;
    bool   is_async;
    int    block;
    int[CASC_MED_MAX] med_idxs;
    String[CASC_MED_MAX] med_names;
    int    med_count;
    int    out_cell;      // -1 = нет
    int    out_frame;
}

struct Block { int kind; int aux; }   // 0 top, 1 proc (aux=idx), 2 casc (aux=seq)

struct LabelDef { String name; int line; int block; bool referenced; }

enum Op : char {
    CAV, RES, MED, RAISE, DECAY, PROBE, CASC, ENDC,
    LOAD, STORE, MOV, ALU3, ALU1, PRINT,
    LABEL, JMP, BRZ, BRNZ, CALL, RET
}

struct Instr {
    Op     op;
    int    line;
    int    func;          // 0 = main, иначе индекс proc (1-based)
    int    block;
    int    a, b, c;       // regs / imm / off / size / casc idx
    int    x, y;          // индексы frame/cell/med/proc
    String s1, s2;        // имена меток / C-оператор
    bool   flag;
}

const int NAME_MAP_MAX = 32768;

struct NameMap {
    String[NAME_MAP_MAX] keys;
    int[NAME_MAP_MAX] values;
    bool[NAME_MAP_MAX] used;
    int count;
}

fn void NameMap.clear(NameMap* map) {
    for (int i = 0; i < NAME_MAP_MAX; i++) map.used[i] = false;
    map.count = 0;
}

fn int? NameMap.get(NameMap* map, String key) {
    usz index = (usz)key.hash() & (NAME_MAP_MAX - 1);
    for (int probes = 0; probes < NAME_MAP_MAX; probes++) {
        if (!map.used[index]) return NOT_FOUND~;
        if (map.keys[index] == key) return map.values[index];
        index = (index + 1) & (NAME_MAP_MAX - 1);
    }
    return NOT_FOUND~;
}

fn bool NameMap.has_key(NameMap* map, String key) {
    return @ok(map.get(key));
}

fn void NameMap.set(NameMap* map, String key, int value) {
    usz index = (usz)key.hash() & (NAME_MAP_MAX - 1);
    for (int probes = 0; probes < NAME_MAP_MAX; probes++) {
        if (map.used[index] && map.keys[index] == key) {
            map.values[index] = value;
            return;
        }
        if (!map.used[index]) {
            assert(map.count < NAME_MAP_MAX);
            map.keys[index] = key;
            map.values[index] = value;
            map.used[index] = true;
            map.count++;
            return;
        }
        index = (index + 1) & (NAME_MAP_MAX - 1);
    }
    unreachable("name map capacity exceeded");
}

// --- глобальное состояние ------------------------------------------------------
List{Frame}   frames;
List{Cell}    cells;
List{Med}     meds;
List{Proc}    procs;
List{Cascade} cascades;
List{Block}   blocks;
List{LabelDef} labels;
List{Instr}   instrs;
NameMap frame_map;
NameMap cell_map;
NameMap med_map;
NameMap proc_map;
NameMap label_map;
NameMap label_names;

// диагностика для LSP-режима (--lsp, lsp_server.c3): те же нарушения, что
// viol() печатает в CLI, но собранные в список вместо stderr
struct Diag {
    int    line;          // 1-based, как в CLI
    String rule;
    String msg;
}
List{Diag} lsp_diags;
bool g_lsp_mode = false;   // --lsp: viol() не печатает, процесс не умирает

uint gencnt = 1;
int  violations = 0;
int  cur_proc = 0;        // 0 = верхний уровень
int  cur_casc = -1;       // индекс каскада или -1
int  top_ret = 0;
int  casc_seq = 0;
bool g_lib_mode = false;   // --emit-lib: C23 без main, proc → rza_NAME
String srcname;

bool g_state_inited = false;

fn int main(String[] args) {
    assert(args.len > 0);
    init_workmem();
    reset_state();
    assert(g_state_inited);

    bool emit_c = false;
    String outpath = "";
    String src = "";
    for (sz i = 1; i < args.len; i++) {
        String a = args[i];
        if (a == "--emit-c") {
            emit_c = true;
        } else if (a == "--emit-lib") {
            emit_c = true;
            g_lib_mode = true;
        } else if (a == "--lsp") {
            return lsp_main();
        } else if (a == "-o") {
            i++;
            if (i >= args.len) {
                io::eprintfn("rez3asm: -o needs an argument");
                return 2;
            }
            outpath = args[i];
        } else if (a.starts_with("-")) {
            io::eprintfn("rez3asm: unknown flag %s", a);
            return 2;
        } else {
            if (src.len > 0) {
                io::eprintfn("rez3asm: expected one input file");
                return 2;
            }
            src = a;
        }
    }
    if (src.len == 0) {
        io::eprintfn("usage: rez3asm file.rza [--emit-c | --emit-lib] [-o file.c] | rez3asm --lsp");
        io::eprintfn("  -o без --emit-c/--emit-lib тоже включает эмиссию C");
        return 2;
    }
    srcname = src;
    char[]? data = file::load(workmem, src);
    if (catch data) {
        io::eprintfn("rez3asm: cannot open %s", src);
        return 2;
    }
    if (data.len > SOURCE_BYTES_MAX) {
        io::eprintfn("rez3asm: source exceeds 1048576 bytes");
        return 1;
    }
    run((String)data);
    if (violations > 0) return 1;
    if (emit_c || outpath.len > 0) {
        String code = emit();
        if (violations > 0) return 1;
        if (outpath.len > 0) {
            if (catch err = file::save(outpath, code)) {
                io::eprintfn("rez3asm: cannot write %s", outpath);
                return 2;
            }
        } else {
            io::print(code);
        }
    }
    return 0;
}

// полный сброс состояния чекера: CLI зовёт один раз, LSP — на каждую
// валидацию (документ проверяется целиком, Full sync)
fn void reset_state() {
    if (!g_state_inited) {
        frames.init(mem, NODE_MAX);
        cells.init(mem, NODE_MAX);
        meds.init(mem, NODE_MAX);
        procs.init(mem, NODE_MAX);
        cascades.init(mem, NODE_MAX);
        blocks.init(mem, NODE_MAX);
        labels.init(mem, NODE_MAX);
        instrs.init(mem, NODE_MAX);
        lsp_diags.init(mem, LSP_DIAG_MAX + 1);
        g_state_inited = true;
    }
    frames.clear();
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
    blocks.push({ .kind = 0, .aux = 0 });   // block 0 = top
    // field — frames[0], бессмертен
    frames.push({ .name = "field", .parent = -1, .first_child = -1,
                  .next_sibling = -1, .alive = true,
                  .gen = nextgen(), .cname = "f_field", .scope = 0,
                  .cap = 64, .is_field = true });
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
fn uint nextgen() { uint g = gencnt; gencnt++; return g; }

fn String cat(String[] parts) {
    DString d = dstring::new_with_capacity(workmem, 64);
    foreach (p : parts) d.append_string(p);
    return d.copy_str(workmem);
}

fn String clip_utf8(String s, sz max) {
    if (s.len <= max) return s;
    sz pos = 0;
    while (pos < max) {
        char c = s[pos];
        sz width = 1;
        if ((c & 0xE0) == 0xC0) { width = 2; }
        else if ((c & 0xF0) == 0xE0) { width = 3; }
        else if ((c & 0xF8) == 0xF0) { width = 4; }
        if (pos + width > max) break;
        bool valid = true;
        for (sz j = 1; j < width; j++) {
            if ((s[pos + j] & 0xC0) != 0x80) { valid = false; break; }
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
            lsp_diags.push({ .line = line, .rule = rule,
                             .msg = clip_utf8(msg, LSP_DIAG_TEXT_MAX) });
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
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                  (c >= 'A' && c <= 'F'))) return false;
        }
        return true;
    }
    for (; i < s.len; i++) {
        if (s[i] < '0' || s[i] > '9') return false;
    }
    return true;
}

fn bool check_name(String name, int line) {
    if (!is_name(name)) {
        viol(line, "STRUCT", cat({"bad name ", name}));
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
    viol(line, "STRUCT", cat({"bad register ", tok, " (want %r0..%r15)"}));
    return -1;
}

// разбить операнды по запятым в buf; возвращает ЧИСЛО токенов
// (считаются все, даже за пределами buf — лишние ловит split_ops_exact)
fn int split_ops(String rest, String[] buf) {
    int n = 0;
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
        viol(line, "STRUCT", cat({"bad operands for ", opname}));
        return false;
    }
    for (int i = 0; i < n; i++) {
        if (buf[i].len == 0) {
            viol(line, "STRUCT", cat({"bad operands for ", opname}));
            return false;
        }
    }
    return true;
}

// --- скоупы ----------------------------------------------------------------------
// возврат: >=0 индекс, -1 unknown. Рамки и ячейки — общая хроника (AUDIT-3),
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

// Имена host API уникальны и проверяются до генерации C (SPEC §11).
fn bool host_name_bad(String name, int line) {
    if (name == "boot" || name == "arena_alloc" || name == "deref_cell" ||
        name.starts_with("frame_") || name.starts_with("med_")) {
        viol(line, "STRUCT", cat({"procedure name ", name,
             " collides with lib host API (SPEC 11)"}));
        return true;
    }
    return false;
}

fn void scope_viol(int line, String kind, String name) {
    viol(line, "SCOPE", cat({kind, " ", name,
        " is not visible from procedure body ",
        "(only proc-locals and field-owned mediators are)"}));
}

fn bool check_dup(String name, int line, int scope) {
    if (try fi = frame_map.get(name)) {
        if (frames[fi].scope == scope) {
            viol(line, "DUP", cat({"duplicate name ", name})); return false;
        }
    }
    if (try ci = cell_map.get(name)) {
        if (cells[ci].scope == scope) {
            viol(line, "DUP", cat({"duplicate name ", name})); return false;
        }
    }
    if (try mi = med_map.get(name)) {
        if (meds[mi].scope == scope) {
            viol(line, "DUP", cat({"duplicate name ", name})); return false;
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
    int fr = cells[meds[mi].cell].owner;
    return frames[fr].alive && meds[mi].gen == frames[fr].gen;
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
    int cur = f;
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

fn int cur_func() { return cur_proc; }   // 0 = main

fn bool at_capacity(sz len, int line, String kind) {
    if (len < NODE_MAX) return false;
    viol(line, "STRUCT", cat({"too many ", kind}));
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
        viol(line, "DUP", cat({"duplicate label ", name}));
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
    return cur_proc > 0 ? cat({prefix, "P_", procs[(sz)(cur_proc - 1)].name,
                               "X", name})
                        : cat({prefix, name});
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
    String name = buf[0];
    String parent = buf[1];
    if (!check_name(name, line)) return;
    int pf = find_frame(parent, cur_proc);
    if (pf < 0) { viol(line, "I1", cat({"unknown parent frame ", parent})); return; }
    if (!frames[pf].alive) {
        viol(line, "I1", cat({"enter under dead frame ", parent})); return;
    }
    if (!check_dup(name, line, 0)) return;
    // Рамка proc живёт в другом scope, но делит host API с новой рамкой.
    if (find_proc(name) >= 0) {
        viol(line, "DUP", cat({"frame shadows procedure ", name}));
        return;
    }
    // Рамки глобальны, включая созданные в proc.
    if (at_capacity(frames.len(), line, "frames")) return;
    Frame f = { .name = name, .parent = pf, .first_child = -1,
                .next_sibling = -1, .line = line, .alive = true,
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
    String name = buf[0];
    String fname = buf[1];
    String ssize = buf[2];
    if (!check_name(name, line)) return;
    // Неверный размер — violation, не молчаливый 0.
    int size = -1;
    if (is_int(ssize)) {
        int? sv = ssize.to_int();
        if (catch sv) {
            viol(line, "STRUCT", cat({"bad size ", ssize,
                                      " (want positive int)"}));
            return;
        }
        size = sv;
    }
    if (size <= 0) {
        viol(line, "STRUCT", cat({"bad size ", ssize, " (want positive int)"}));
        return;
    }
    int f = find_frame(fname, cur_proc);
    if (f < 0) {
        viol(line, "I1", cat({"cell in unknown frame ", name, " ", fname})); return;
    }
    if (!frames[f].alive) {
        viol(line, "I1", cat({"cell in dead frame ", name, " ", fname})); return;
    }
    if (size > 2147483632) {
        viol(line, "STRUCT", "aligned cell size out of i32 range");
        return;
    }
    int aligned = (size + 15) & ~15;
    if (frames[f].res_bytes > 2147483647 - aligned) {
        viol(line, "STRUCT", cat({"frame capacity out of i32 range: ", fname}));
        return;
    }
    if (!check_dup(name, line, 0)) return;
    // Ячейки глобальны (scope 0).
    if (at_capacity(cells.len(), line, "cells")) return;
    Cell cc = { .name = name, .owner = f, .home = f, .size = size,
                .cname = cname_for("c_", name), .scope = 0 };
    cells.push(cc);
    cell_map.set(name, (int)cells.len() - 1);
    frames[f].res_bytes += aligned;
    add_instr({ .op = Op.RES, .line = line, .x = (int)cells.len() - 1,
                .y = f, .a = size });
}

fn void op_med(String rest, int line) {
    assert(line > 0);
    assert(rest.len <= SOURCE_BYTES_MAX);
    String[3] buf;
    if (!split_ops_exact(rest, 3, line, "med", &buf)) return;
    String name = buf[0];
    String cn = buf[1];
    String issuer = buf[2];
    if (!check_name(name, line)) return;
    if (!name.ends_with("_m")) {
        viol(line, "STRUCT", cat({"mediator name ", name, " must end with _m"}));
        return;
    }
    int ci = find_cell(cn, cur_proc);
    if (ci < 0) {
        viol(line, "I2", cat({"link to unknown cell ", name, " ", cn})); return;
    }
    int is = find_frame(issuer, cur_proc);
    if (is < 0) { viol(line, "I2", cat({"unknown issuer frame ", issuer})); return; }
    if (!is_ancestor(cells[ci].owner, is, false)) {
        viol(line, "I2", cat({"link issued by non-owner non-ancestor ",
                              issuer, " ", cn}));
        return;
    }
    if (!check_dup(name, line, cur_proc)) return;
    // Host API экспортирует каждый медиатор: имя глобально уникально.
    if (med_map.has_key(name)) {
        viol(line, "DUP", cat({"duplicate mediator ", name,
             " (host API exports every mediator, SPEC 11)"}));
        return;
    }
    if (at_capacity(meds.len(), line, "mediators")) return;
    if (cells[ci].med_count >= CELL_MED_MAX) {
        viol(line, "STRUCT", "too many mediators for one cell");
        return;
    }
    Med m = { .name = name, .cell = ci, .owner = cells[ci].owner,
              .gen = frames[cells[ci].owner].gen,
              .cname = cname_for("m_", name), .scope = cur_proc };
    meds.push(m);
    int mi = (int)meds.len() - 1;
    med_map.set(name, mi);
    cells[ci].med_idxs[cells[ci].med_count] = mi;
    cells[ci].med_count++;
    add_instr({ .op = Op.MED, .line = line, .x = mi });
}

fn void op_raise(String rest, int line) {
    assert(line > 0);
    assert(rest.len <= SOURCE_BYTES_MAX);
    String[2] buf;
    if (!split_ops_exact(rest, 2, line, "raise", &buf)) return;
    String cn = buf[0];
    String fname = buf[1];
    int ci = find_cell(cn, cur_proc);
    if (ci < 0) { viol(line, "I4", cat({"raise of unknown cell ", cn})); return; }
    int f = find_frame(fname, cur_proc);
    if (f < 0) { viol(line, "I4", cat({"raise to unknown frame ", fname})); return; }
    if (!is_ancestor(cells[ci].owner, f, true)) {
        viol(line, "I4", cat({"raise to non-ancestor (sideways/down forbidden) ",
                              cn, " ", fname}));
        return;
    }
    if (!frames[f].alive) {
        viol(line, "I4", cat({"raise into dead frame ", cn, " ", fname})); return;
    }
    if (!frames[cells[ci].owner].alive) {
        viol(line, "I4", cat({"raise of cell in dead frame ", cn, " ",
                              frames[cells[ci].owner].name}));
        return;
    }
    cells[ci].owner = f;   // Новые медиаторы используют нового владельца.
    add_instr({ .op = Op.RAISE, .line = line, .x = ci, .y = f });
}

fn void op_decay(String rest, int line) {
    assert(line > 0);
    assert(rest.len <= SOURCE_BYTES_MAX);
    String[1] buf;
    if (!split_ops_exact(rest, 1, line, "decay", &buf)) return;
    String fname = buf[0];
    int f = find_frame(fname, cur_proc);
    if (f < 0) { viol(line, "DECAY", cat({"leave of unknown frame ", fname})); return; }
    if (frames[f].is_field) {
        viol(line, "DECAY", cat({"leave of root (field) forbidden ", fname})); return;
    }
    if (cur_proc > 0 && f == procs[(sz)(cur_proc - 1)].frame) {
        viol(line, "DECAY", cat({"leave of procedure frame ", fname, " (use ret)"}));
        return;
    }
    if (!frames[f].alive) { viol(line, "DECAY", cat({"double leave ", fname})); return; }
    kill(f);
    add_instr({ .op = Op.DECAY, .line = line, .x = f });
}

fn void op_probe(String rest, int line) {
    assert(line > 0);
    assert(rest.len <= SOURCE_BYTES_MAX);
    String[1] buf;
    if (!split_ops_exact(rest, 1, line, "probe", &buf)) return;
    String mname = buf[0];
    int mi = find_med(mname, cur_proc);
    if (mi == -2) { scope_viol(line, "mediator", mname); return; }
    if (mi < 0) {
        viol(line, "STRUCT", cat({"probe of unknown mediator ", mname})); return;
    }
    add_instr({ .op = Op.PROBE, .line = line, .x = mi });
}

// --- память через медиатор -------------------------------------------------------
// разбор "[med + off]"; при ошибке violation записано, возврат false
fn bool parse_mem(String tok, int line, String* mname, int* off, int* off_reg) {
    String t = tok.trim();
    *off_reg = -1;
    bool bad = false;
    if (t.len < 5 || t[0] != '[' || t[t.len - 1] != ']') {
        bad = true;
    } else {
        String inner = t[1..t.len - 2];
        sz? pi = inner.index_of_char('+');
        if (catch pi) {
            bad = true;
        } else {
            *mname = inner[:pi].trim();
            String os = inner[pi + 1..].trim();
            if (!is_name(*mname)) {
                bad = true;
            } else if (is_int(os)) {
                // Смещение вне i32 — violation, не молчаливый wrap.
                int? v = os.to_int();
                if (catch v) {
                    viol(line, "STRUCT",
                         cat({"mem offset out of i32 range: ", os}));
                    return false;
                }
                *off = v;
            } else if (os.len > 0 && os[0] == '%') {
                int r = parse_reg(os, line);    // AUDIT-4: [med + %rN]
                if (r < 0) { bad = true; } else { *off_reg = r; }
            } else {
                bad = true;
            }
        }
    }
    if (bad) {
        viol(line, "STRUCT", cat({"bad memory operand ", tok,
                                  " (want [med + off])"}));
        return false;
    }
    return true;
}

// разрешение медиатора для load/store; -1 = ошибка (violation записано)
fn int resolve_mem_med(String tok, int line, String opname, int* off, int* off_reg) {
    String mname;
    if (!parse_mem(tok, line, &mname, off, off_reg)) return -1;
    int mi = find_med(mname, cur_proc);
    if (mi == -2) { scope_viol(line, "mediator", mname); return -1; }
    if (mi < 0) {
        viol(line, "STRUCT", cat({opname, " via unknown mediator ", mname}));
        return -1;
    }
    int width = opname == "loadb" ? 1 : 8;
    int size = cells[meds[mi].cell].size;
    if (*off_reg < 0 && (*off < 0 || *off > size || width > size - *off)) {
        viol(line, "STRUCT", cat({opname, " out of bounds via ", mname}));
        return -1;
    }
    if (cur_casc >= 0) {
        bool ok = false;
        foreach (mn : cascades[cur_casc].med_names[:cascades[cur_casc].med_count]) {
            if (mn == mname) { ok = true; break; }
        }
        if (!ok) {
            viol(line, "STRUCT",
                 cat({"cascade body addresses non-input mediator ", mname}));
            return -1;
        }
    }
    // AUDIT-1/#3: статически мёртвый медиатор — НЕ violation (runtime-fault)
    return mi;
}

fn void op_load2(String rest, int line, bool is_byte) {
    String[2] buf;
    if (!split_ops_exact(rest, 2, line, is_byte ? "loadb" : "load", &buf)) return;
    int dst = parse_reg(buf[0], line);
    int off = 0;
    int off_reg = -1;
    int mi = resolve_mem_med(buf[1], line, is_byte ? "loadb" : "load", &off, &off_reg);
    if (dst < 0 || mi < 0) return;
    add_instr({ .op = Op.LOAD, .line = line, .a = dst, .x = mi, .b = off,
                .c = off_reg, .flag = is_byte });
}

fn void op_store(String rest, int line) {
    assert(line > 0);
    assert(rest.len <= SOURCE_BYTES_MAX);
    String[2] buf;
    if (!split_ops_exact(rest, 2, line, "store", &buf)) return;
    int off = 0;
    int off_reg = -1;
    int mi = resolve_mem_med(buf[0], line, "store", &off, &off_reg);
    int src = parse_reg(buf[1], line);
    if (mi < 0 || src < 0) return;
    add_instr({ .op = Op.STORE, .line = line, .a = src, .x = mi, .b = off,
                .c = off_reg, .flag = false });
}

// --- данные и поток ----------------------------------------------------------------
fn void op_mov(String rest, int line) {
    assert(line > 0);
    assert(rest.len <= SOURCE_BYTES_MAX);
    String[2] buf;
    if (!split_ops_exact(rest, 2, line, "mov", &buf)) return;
    int dst = parse_reg(buf[0], line);
    if (dst < 0) return;
    if (is_int(buf[1])) {
        int? v = buf[1].to_int();
        if (catch v) {
            viol(line, "STRUCT", cat({"immediate out of i32 range: ", buf[1]}));
            return;
        }
        add_instr({ .op = Op.MOV, .line = line, .a = dst,
                    .b = v, .flag = true });
        return;
    }
    int src = parse_reg(buf[1], line);
    if (src < 0) return;
    add_instr({ .op = Op.MOV, .line = line, .a = dst, .b = src, .flag = false });
}

fn void op_alu3(String opname, String coper, String rest, int line) {
    assert(line > 0);
    assert(rest.len <= SOURCE_BYTES_MAX);
    String[3] buf;
    if (!split_ops_exact(rest, 3, line, opname, &buf)) return;
    int d = parse_reg(buf[0], line);
    int a = parse_reg(buf[1], line);
    if (d < 0 || a < 0) return;
    // AUDIT-5: третий операнд — imm (флаг) или регистр
    if (is_int(buf[2])) {
        int? v = buf[2].to_int();
        if (catch v) {
            viol(line, "STRUCT", cat({"immediate out of i32 range: ", buf[2]}));
            return;
        }
        add_instr({ .op = Op.ALU3, .line = line, .a = d, .b = a, .c = v,
                    .s2 = coper, .flag = true });
        return;
    }
    int b = parse_reg(buf[2], line);
    if (b < 0) return;
    add_instr({ .op = Op.ALU3, .line = line, .a = d, .b = a, .c = b,
                .s2 = coper, .flag = false });
}

fn void op_alu1(String rest, int line, bool is_inc) {
    String[1] buf;
    if (!split_ops_exact(rest, 1, line, is_inc ? "inc" : "dec", &buf)) return;
    int r = parse_reg(buf[0], line);
    if (r < 0) return;
    add_instr({ .op = Op.ALU1, .line = line, .a = r, .flag = is_inc });
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
    add_instr({ .op = is_brz ? Op.BRZ : Op.BRNZ, .line = line,
                .a = r, .s1 = buf[1] });
}

fn void op_call(String rest, int line) {
    assert(line > 0);
    assert(rest.len <= SOURCE_BYTES_MAX);
    String name = rest.trim();
    if (!check_name(name, line)) return;
    if (cur_proc > 0 && name == procs[(usz)(cur_proc - 1)].name) {
        viol(line, "STRUCT", cat({"recursive call of ", name,
             " (frame_reset frees the live arena)"}));
        return;
    }
    int pi = find_proc(name);
    if (pi < 0) {
        viol(line, "STRUCT", cat({"call of unknown procedure ", name}));
        return;
    }
    procs[pi].called = true;
    add_instr({ .op = Op.CALL, .line = line, .x = pi });
}

// --- proc / casc ---------------------------------------------------------------------
fn void open_proc(String name, int line) {
    if (find_proc(name) >= 0) {
        viol(line, "DUP", cat({"duplicate procedure ", name}));
        return;
    }
    if (host_name_bad(name, line)) return;
    if (find_frame(name, 0) >= 0 || cur_proc > 0 && find_frame(name, cur_proc) >= 0) {
        viol(line, "DUP", cat({"procedure shadows frame ", name}));
        return;
    }
    if (at_capacity(frames.len(), line, "frames")) return;
    if (at_capacity(procs.len(), line, "procedures")) return;
    if (at_capacity(blocks.len(), line, "blocks")) return;
    blocks.push({ .kind = 1, .aux = (int)procs.len() });
    Frame f = { .name = name, .parent = 0, .first_child = -1,
                .next_sibling = -1, .line = line, .alive = true,
                .gen = nextgen(), .cname = cat({"f_P_", name}),
                .scope = (int)procs.len() + 1, .cap = 64, .is_procframe = true };
    frames.push(f);
    int fi = (int)frames.len() - 1;
    link_frame(fi, 0);
    frame_map.set(name, fi);
    Proc p = { .name = name, .line = line, .frame = fi,
               .block = (int)blocks.len() - 1, .cname = cat({"p_", name}) };
    procs.push(p);
    proc_map.set(name, (int)procs.len() - 1);
    cur_proc = (int)procs.len();   // 1-based
}

fn void do_ret(int line) {
    if (cur_proc > 0) {
        add_instr({ .op = Op.RET, .line = line });
        // Чекер и runtime разрушают рамку proc и её поддерево (AUDIT-7).
        kill(procs[(sz)(cur_proc - 1)].frame);
        cur_proc = 0;
        return;
    }
    add_instr({ .op = Op.RET, .line = line });
    if (top_ret == 0) top_ret = line;
}

fn bool parse_casc_header(String rest, int line, bool is_async,
                          String* name, String* medstr,
                          String* outname, String* outfname) {
    sz? ci = rest.index_of_char(':');
    if (catch ci) { viol(line, "STRUCT", "malformed cascade header"); return false; }
    *name = rest[:ci].trim();
    String r2 = rest[ci + 1..];
    sz? ai = r2.index_of("->");
    if (catch ai) { viol(line, "STRUCT", "malformed cascade header"); return false; }
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
    if (is_async && outfname.len > 0) {
        viol(line, "STRUCT", "acasc out frame is implicit (always field)");
        return false;
    }
    return true;
}

fn void add_casc_input(String tok, int line, String name, bool is_async,
                       int[] med_idxs, String[] med_names, int* count) {
    if (tok.len == 0 || !check_name(tok, line)) return;
    int mdi = find_med(tok, cur_proc);
    if (mdi == -2) { scope_viol(line, "mediator", tok); return; }
    if (mdi < 0) {
        viol(line, "I3", cat({"cascade uses unknown link ", name, " ", tok}));
        return;
    }
    if (*count >= CASC_MED_MAX) {
        viol(line, "STRUCT", "too many cascade inputs");
        return;
    }
    foreach (prev : med_names[:(*count)]) {
        if (prev == meds[mdi].name) {
            viol(line, "DUP", cat({"cascade ", name, ": duplicate input link ", tok}));
        }
    }
    med_idxs[*count] = mdi;
    med_names[*count] = meds[mdi].name;
    (*count)++;
    if (is_async) {
        if (!frames[cells[meds[mdi].cell].owner].is_field) {
            viol(line, "I3", cat({"async cascade holds non-root link ", name, " ", tok}));
        }
    } else if (!med_alive(mdi)) {
        viol(line, "I3", cat({"sync cascade aborted: dead link on entry ",
                              name, " ", tok}));
    }
}

fn int open_casc_out(String outname, String outfname, bool is_async,
                     int line, int* out_frame) {
    if (!check_name(outname, line) || !check_dup(outname, line, 0)) return -1;
    *out_frame = is_async ? 0 : find_frame(outfname, cur_proc);
    if (*out_frame < 0) {
        viol(line, "I3", cat({"out cell in unknown frame ", outname, " ", outfname}));
        return -1;
    }
    if (!frames[*out_frame].alive) {
        viol(line, "I1", cat({"cell in dead frame ", outname, " ",
                              frames[*out_frame].name}));
    }
    if (at_capacity(cells.len(), line, "cells")) return -1;
    Cell oc = { .name = outname, .owner = *out_frame, .home = *out_frame,
                .size = 8, .cname = cname_for("c_", outname), .scope = 0 };
    cells.push(oc);
    cell_map.set(outname, (int)cells.len() - 1);
    frames[*out_frame].outs += 1;
    return (int)cells.len() - 1;
}

fn void open_casc(String rest, int line, bool is_async) {
    String name, medstr, outname, outfname;
    if (!parse_casc_header(rest, line, is_async, &name, &medstr,
                           &outname, &outfname)) return;
    if (!check_name(name, line)) return;
    if (at_capacity(cascades.len(), line, "cascades")) return;
    if (at_capacity(blocks.len(), line, "blocks")) return;
    int[CASC_MED_MAX] med_idxs;
    String[CASC_MED_MAX] med_names;
    int count = 0;
    if (medstr.len == 0) {
        viol(line, "STRUCT", cat({"cascade ", name, " without input mediators"}));
    }
    String ms = medstr;
    while (ms.len > 0) {
        sz? mi2 = ms.index_of_char(',');
        String tok;
        if (catch mi2) { tok = ms.trim(); ms = ""; }
        else { tok = ms[:mi2].trim(); ms = ms[mi2 + 1..]; }
        add_casc_input(tok, line, name, is_async, med_idxs[..], med_names[..], &count);
    }
    int out_frame = -1;
    int out_cell = open_casc_out(outname, outfname, is_async, line, &out_frame);
    casc_seq++;
    blocks.push({ .kind = 2, .aux = casc_seq });
    Cascade ca = { .name = name, .line = line, .seq = casc_seq,
                   .is_async = is_async, .block = (int)blocks.len() - 1,
                   .med_idxs = med_idxs, .med_names = med_names,
                   .med_count = count, .out_cell = out_cell, .out_frame = out_frame };
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
fn bool casc_body_ok(String op) {
    switch (op) {
        case "mov": case "store": case "load": case "loadb": case "print":
        case "jmp": case "brz": case "brnz": case "inc": case "dec":
        case "add": case "sub": case "mul": case "div": case "mod":
        case "and": case "or": case "xor": case "shl": case "shr":
            return true;
        default:
            return false;
    }
}

fn void parse_instr(String line, int n, bool in_casc) {
    sz sp = (sz)line.len;
    for (sz i = 0; i < line.len; i++) {
        if (line[i] == ' ' || line[i] == '\t') { sp = i; break; }
    }
    String op = line[:sp];
    String rest = (sp < line.len) ? line[sp + 1..].trim() : "";
    if (in_casc && !casc_body_ok(op)) {
        viol(n, "STRUCT", cat({"op ", op,
             " not allowed in cascade body (data instructions only)"}));
        return;
    }
    if (op == "cav") { op_cav(rest, n); }
    else if (op == "res") { op_res(rest, n); }
    else if (op == "med") { op_med(rest, n); }
    else if (op == "raise") { op_raise(rest, n); }
    else if (op == "decay") { op_decay(rest, n); }
    else if (op == "probe") { op_probe(rest, n); }
    else if (op == "load") { op_load2(rest, n, false); }
    else if (op == "loadb") { op_load2(rest, n, true); }
    else if (op == "store") { op_store(rest, n); }
    else if (op == "mov") { op_mov(rest, n); }
    else if (op == "add") { op_alu3(op, "+", rest, n); }
    else if (op == "sub") { op_alu3(op, "-", rest, n); }
    else if (op == "mul") { op_alu3(op, "*", rest, n); }
    else if (op == "div") { op_alu3(op, "/", rest, n); }
    else if (op == "mod") { op_alu3(op, "%", rest, n); }
    else if (op == "and") { op_alu3(op, "&", rest, n); }
    else if (op == "or")  { op_alu3(op, "|", rest, n); }
    else if (op == "xor") { op_alu3(op, "^", rest, n); }
    else if (op == "shl") { op_alu3(op, "<<", rest, n); }
    else if (op == "shr") { op_alu3(op, ">>", rest, n); }
    else if (op == "inc") { op_alu1(rest, n, true); }
    else if (op == "dec") { op_alu1(rest, n, false); }
    else if (op == "print") { op_print(rest, n); }
    else if (op == "jmp") { op_jmp(rest, n); }
    else if (op == "brz") { op_br(rest, n, true); }
    else if (op == "brnz") { op_br(rest, n, false); }
    else if (op == "call") { op_call(rest, n); }
    else { viol(n, "STRUCT", cat({"unknown op ", op})); }
}

// --- главный цикл разбора -----------------------------------------------------------------
fn void open_proc_line(String line, int n, int sp) {
    if (cur_proc > 0) {
        viol(n, "STRUCT", cat({"nested proc ", line[sp..].trim()}));
        return;
    }
    String pnm = line[sp..].trim();
    if (pnm.len > 1 && pnm[pnm.len - 1] == ':') {
        pnm = pnm[:pnm.len - 1].trim();
    }
    if (!is_name(pnm)) {
        viol(n, "STRUCT", "malformed proc header");
        return;
    }
    open_proc(pnm, n);
}

fn void run(String text) {
    String[] lines = text.split(workmem, "\n");
    for (sz i = 0; i < lines.len; i++) {
        int n = (int)i + 1;
        String raw = lines[i];
        sz? sci = raw.index_of_char(';');
        String line = raw.trim();
        if (try sci) line = raw[:sci].trim();
        if (line.len == 0) continue;
        // код после верхнеуровневого ret — violation (каждая строка)
        if (cur_proc == 0 && cur_casc < 0 && top_ret > 0) {
            viol(n, "STRUCT", "code after top-level ret");
        }
        if (cur_casc >= 0) {
            if (line == "endc") { end_casc(n); continue; }
            if (line.len > 1 && line[line.len - 1] == ':'
                    && is_name(line[:line.len - 1])) {
                add_label(line[:line.len - 1], n);
                continue;
            }
            parse_instr(line, n, true);
            continue;
        }
        if (line == "endc") { viol(n, "STRUCT", "endc without casc"); continue; }
        if (line.len > 1 && line[line.len - 1] == ':'
                && is_name(line[:line.len - 1])) {
            add_label(line[:line.len - 1], n);
            continue;
        }
        // служебные слова
        sz sp = (sz)line.len;
        for (sz j = 0; j < line.len; j++) {
            if (line[j] == ' ' || line[j] == '\t') { sp = j; break; }
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
        if (line == "ret") { do_ret(n); continue; }
        parse_instr(line, n, false);
    }
    if (cur_casc >= 0) {
        viol(cascades[cur_casc].line, "STRUCT",
             cat({"unterminated cascade ", cascades[cur_casc].name,
                  " (missing endc)"}));
    }
    if (cur_proc > 0) {
        viol(procs[(sz)(cur_proc - 1)].line, "STRUCT",
             cat({"unterminated proc ", procs[(sz)(cur_proc - 1)].name,
                  " (missing ret)"}));
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
            viol(ins.line, "STRUCT",
                 cat({"jump to label ", ins.s1, " of another lexical block ",
                      "(cross-block jumps are forbidden)"}));
        } else {
            viol(ins.line, "STRUCT",
                 cat({"jump to unknown label ", ins.s1}));
        }
    }
}

const long ARENA_FRAME_MAX = 16777216;
const long ARENA_TOTAL_MAX = 67108864;

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
struct Output {
    DString text;
    sz max_bytes;
    bool overflow;
}

fn void Output.init(Output* out, sz initial_bytes, sz max_bytes) {
    assert(initial_bytes > 0);
    assert(max_bytes > 0);
    sz capacity = initial_bytes < max_bytes ? initial_bytes : max_bytes;
    out.text = dstring::new_with_capacity(workmem, capacity);
    out.max_bytes = max_bytes;
    out.overflow = false;
}

fn bool Output.reserve(Output* out, sz amount) {
    assert(out.max_bytes > 0);
    if (out.overflow) return false;
    if (out.text.len() > out.max_bytes) {
        out.overflow = true;
        return false;
    }
    if (amount > out.max_bytes - out.text.len()) {
        out.overflow = true;
        return false;
    }
    return true;
}

fn sz? Output.write(Output* out, char[] bytes) @dynamic {
    if (!out.reserve(bytes.len)) return io::BUFFER_EXCEEDED~;
    out.text.append_string((String)bytes);
    return bytes.len;
}

fn void? Output.write_byte(Output* out, char c) @dynamic {
    char[1] byte = { c };
    if (catch written = out.write(byte[..])) return written~;
    return;
}

fn void Output.append_string(Output* out, String text) {
    if (!out.reserve(text.len)) return;
    out.text.append_string(text);
    assert(out.text.len() <= out.max_bytes);
}

fn sz? Output.appendf(Output* out, String format, args...) @maydiscard @format(1) {
    return io::fprintf((OutStream)out, format, ...args);
}

fn sz Output.len(Output* out) {
    assert(out.text.len() <= out.max_bytes);
    return out.text.len();
}

fn String Output.str_view(Output* out) {
    assert(out.text.len() <= out.max_bytes);
    return out.text.str_view();
}

fn String fexpr(int fi) {
    Frame* f = &frames[fi];
    if (f.is_field) return "f_field";
    if (f.is_procframe) return cat({"&", f.cname});
    return f.cname;
}

fn String label_cname(int block, String name) {
    Block b = blocks[block];
    switch (b.kind) {
        case 0: return cat({"L_", name});
        case 1: return cat({"L_P_", procs[b.aux].name, "X", name});
        default: {
            DString d = dstring::new_with_capacity(workmem, 32);
            d.appendf("L_C%d_%s", b.aux, name);
            return d.copy_str(workmem);
        }
    }
}

fn void pad(Output* out, int ind) {
    for (int i = 0; i < ind; i++) out.append_string("    ");
}

// битмаски чтения/записи регистров функции
fn void scan_regs(int func, uint* rd, uint* wr) {
    *rd = 0; *wr = 0;
    for (sz i = 0; i < instrs.len(); i++) {
        Instr* ins = &instrs[i];
        if (ins.func != func) continue;
        switch (ins.op) {
            case Op.LOAD:
                *wr |= 1u << ins.a;
                if (ins.c >= 0) *rd |= 1u << ins.c;
            case Op.STORE:
                *rd |= 1u << ins.a;
                if (ins.c >= 0) *rd |= 1u << ins.c;
            case Op.MOV:
                *wr |= 1u << ins.a;
                if (!ins.flag) *rd |= 1u << ins.b;
            case Op.ALU3:
                *wr |= 1u << ins.a;
                *rd |= 1u << ins.b;
                if (!ins.flag) *rd |= 1u << ins.c;
            case Op.ALU1:
                *rd |= 1u << ins.a;
                *wr |= 1u << ins.a;
            case Op.PRINT: *rd |= 1u << ins.a;
            case Op.BRZ:   *rd |= 1u << ins.a;
            case Op.BRNZ:  *rd |= 1u << ins.a;
            default: break;
        }
    }
}

fn void emit_regs_decl(Output* out, int ind, uint mask) {
    bool has_any = false;
    for (int r = 0; r < 16; r++) {
        if (mask & (1u << r)) has_any = true;
    }
    if (!has_any) return;
    pad(out, ind);
    out.append_string("int64_t ");
    bool first = true;
    for (int r = 0; r < 16; r++) {
        if (mask & (1u << r)) {
            if (!first) out.append_string(", ");
            out.appendf("r%d = 0", r);
            first = false;
        }
    }
    out.append_string(";\n");
}

fn void emit_writeonly_silence(Output* out, int ind, uint rd, uint wr) {
    for (int r = 0; r < 16; r++) {
        if ((wr & (1u << r)) != 0 && (rd & (1u << r)) == 0) {
            pad(out, ind);
            out.appendf("(void)r%d;\n", r);
        }
    }
}

// Глобальный медиатор инициализируется при создании res или OUT (AUDIT-4).
fn void emit_hoisted_meds(Output* out, int ind, int cell) {
    for (int i = 0; i < cells[cell].med_count; i++) {
        int mi = cells[cell].med_idxs[i];
        if (meds[mi].scope != 0) continue;
        pad(out, ind);
        out.appendf("%s = rez_issue_cell(%s, %s, %s, %d);\n",
                    meds[mi].cname, fexpr(meds[mi].owner),
                    fexpr(cells[cell].home), cells[cell].cname, cells[cell].size);
    }
}

// Потомок может не создаться в этом проходе: guard обязателен.
fn void emit_decay_subtree(Output* out, int ind, int f) {
    uint decay_id = frames[f].decay_id;
    int cur = subtree_next(f, f);
    assert(decay_id > 0);
    while (cur >= 0) {
        if (frames[cur].decay_id < decay_id) {
            cur = subtree_sibling_next(f, cur);
            continue;
        }
        assert(frames[cur].decay_id == decay_id);
        if (!frames[cur].is_field && !frames[cur].is_procframe) {
            pad(out, ind);
            out.appendf("if (%s) rez_decay(%s);\n",
                        frames[cur].cname, frames[cur].cname);
        }
        cur = subtree_next(f, cur);
    }
}

fn void emit_bounds_guard(Output* out, int ind, Instr* ins) {
    if (ins.c < 0) return;
    int width = ins.op == Op.LOAD && ins.flag ? 1 : 8;
    pad(out, ind);
    out.appendf("if (!rez_cell_bounds(%s, r%d, %d)) {\n",
                meds[ins.x].cname, ins.c, width);
    pad(out, ind + 1);
    out.appendf("fprintf(stderr, \"FAULT line %d: out of bounds %s\\n\");\n",
                ins.line, meds[ins.x].name);
    pad(out, ind + 1);
    out.append_string("exit(1);\n");
    pad(out, ind);
    out.append_string("}\n");
}

fn void emit_load(Output* out, int ind, Instr* ins, bool in_casc) {
    DString oex = dstring::new(workmem);
    defer oex.free();
    if (ins.c >= 0) { oex.appendf("r%d", ins.c); }
    else { oex.appendf("%d", ins.b); }
    String ptr = in_casc ? cat({"p_", meds[ins.x].name}) : "p";
    if (!in_casc) {
        pad(out, ind);
        out.appendf("{ void *p = rez_deref_cell(%s);\n", meds[ins.x].cname);
        pad(out, ind);
        out.appendf("  if (!p) { fprintf(stderr, \"FAULT line %d: "
                    "dead mediator %s\\n\"); exit(1); }\n",
                    ins.line, meds[ins.x].name);
        ind++;
    }
    emit_bounds_guard(out, ind, ins);
    pad(out, ind);
    if (ins.flag) {
        out.appendf("r%d = (int64_t)*(unsigned char*)((char*)%s + %s);",
                    ins.a, ptr, oex.str_view());
    } else {
        out.appendf("memcpy(&r%d, (char*)%s + %s, 8);",
                    ins.a, ptr, oex.str_view());
    }
    out.append_string(in_casc ? "\n" : " }\n");
}

fn void emit_store(Output* out, int ind, Instr* ins, bool in_casc) {
    DString sex = dstring::new(workmem);
    defer sex.free();
    if (ins.c >= 0) { sex.appendf("r%d", ins.c); }
    else { sex.appendf("%d", ins.b); }
    String ptr = in_casc ? cat({"p_", meds[ins.x].name}) : "p";
    if (!in_casc) {
        pad(out, ind);
        out.appendf("{ void *p = rez_deref_cell(%s);\n", meds[ins.x].cname);
        pad(out, ind);
        out.appendf("  if (!p) { fprintf(stderr, \"FAULT line %d: "
                    "dead mediator %s\\n\"); exit(1); }\n",
                    ins.line, meds[ins.x].name);
        ind++;
    }
    emit_bounds_guard(out, ind, ins);
    pad(out, ind);
    out.appendf("memcpy((char*)%s + %s, &r%d, 8);",
                ptr, sex.str_view(), ins.a);
    out.append_string(in_casc ? "\n" : " }\n");
}

fn void emit_alu3(Output* out, int ind, Instr* ins) {
    DString rhs = dstring::new(workmem);
    defer rhs.free();
    if (ins.flag) { rhs.appendf("%d", ins.c); }
    else { rhs.appendf("r%d", ins.c); }
    bool division = ins.s2 == "/" || ins.s2 == "%";
    bool shift = ins.s2 == "<<" || ins.s2 == ">>";
    if (division) {
        pad(out, ind);
        out.appendf("if (%s == 0 || (r%d == INT64_MIN && %s == -1)) {\n",
                    rhs.str_view(), ins.b, rhs.str_view());
        pad(out, ind + 1);
        out.appendf("fprintf(stderr, \"FAULT line %d: division\\n\");\n", ins.line);
        pad(out, ind + 1);
        out.append_string("exit(1);\n");
        pad(out, ind);
        out.append_string("}\n");
    }
    if (shift) {
        pad(out, ind);
        out.appendf("if (%s < 0 || %s >= 64) {\n",
                    rhs.str_view(), rhs.str_view());
        pad(out, ind + 1);
        out.appendf("fprintf(stderr, \"FAULT line %d: shift\\n\");\n", ins.line);
        pad(out, ind + 1);
        out.append_string("exit(1);\n");
        pad(out, ind);
        out.append_string("}\n");
    }
    String helper = "";
    if (ins.s2 == "+") helper = "rez_i64_add";
    if (ins.s2 == "-") helper = "rez_i64_sub";
    if (ins.s2 == "*") helper = "rez_i64_mul";
    if (ins.s2 == "/") helper = "rez_i64_div";
    if (ins.s2 == "%") helper = "rez_i64_mod";
    if (ins.s2 == "<<") helper = "rez_i64_shl";
    if (ins.s2 == ">>") helper = "rez_i64_shr";
    pad(out, ind);
    if (helper.len > 0) {
        out.appendf("r%d = %s(r%d, %s);\n",
                    ins.a, helper, ins.b, rhs.str_view());
    } else {
        out.appendf("r%d = r%d %s %s;\n", ins.a, ins.b, ins.s2, rhs.str_view());
    }
}

fn void emit_label(Output* out, int ind, Instr* ins) {
    int? li = label_map.get(label_key(ins.block, ins.s1));
    if (catch li) return;
    if (!labels[li].referenced) return;
    pad(out, ind);
    out.appendf("%s:\n", label_cname(ins.block, ins.s1));
}

fn void emit_own(Output* out, int ind, Instr* ins) {
    switch (ins.op) {
        case Op.CAV:
            pad(out, ind);
            out.appendf("%s = rez_cav_enter(\n", frames[ins.x].cname);
            pad(out, ind + 1);
            out.appendf("%s, %s, A_%s, %d\n",
                        frames[ins.x].cname, fexpr(ins.y),
                        frames[ins.x].cname, frames[ins.x].cap);
            pad(out, ind);
            out.append_string(");\n");
            pad(out, ind);
            out.appendf("if (!%s) {\n", frames[ins.x].cname);
            pad(out, ind + 1);
            out.appendf("fprintf(stderr, \"FAULT line %d: frame allocation %s\\n\");\n",
                        ins.line, frames[ins.x].name);
            pad(out, ind + 1);
            out.append_string("exit(1);\n");
            pad(out, ind);
            out.append_string("}\n");
        case Op.RES:
            pad(out, ind);
            out.appendf("%s = rez_cell_z(%s, %d);\n",
                        cells[ins.x].cname, fexpr(ins.y), ins.a);
            pad(out, ind);
            out.appendf("if (!%s) {\n", cells[ins.x].cname);
            pad(out, ind + 1);
            out.appendf("fprintf(stderr, \"FAULT line %d: arena overflow (cell %s)\\n\");\n",
                        ins.line, cells[ins.x].name);
            pad(out, ind + 1);
            out.append_string("exit(1);\n");
            pad(out, ind);
            out.append_string("}\n");
            emit_hoisted_meds(out, ind, ins.x);
        case Op.MED:
            if (ins.func == 0) break;
            pad(out, ind);
            int ci = meds[ins.x].cell;
            out.appendf("%s = rez_issue_cell(\n", meds[ins.x].cname);
            pad(out, ind + 1);
            out.appendf("%s, %s, %s, %d\n",
                        fexpr(meds[ins.x].owner), fexpr(cells[ci].home),
                        cells[ci].cname, cells[ci].size);
            pad(out, ind);
            out.append_string(");\n");
        case Op.RAISE:
            pad(out, ind);
            out.appendf("/* raise %s -> %s (line %d): static-only, "
                        "no code (SPEC 9) */\n",
                        cells[ins.x].name, frames[ins.y].name, ins.line);
        case Op.DECAY:
            emit_decay_subtree(out, ind, ins.x);
            pad(out, ind);
            out.appendf("if (%s) rez_decay(%s);\n", fexpr(ins.x), fexpr(ins.x));
        case Op.PROBE:
            pad(out, ind);
            out.appendf("printf(\"%%s\\n\", rez_deref_cell(%s) ? "
                        "\"ALIVE\" : \"DEAD\");\n", meds[ins.x].cname);
        default: break;
    }
}

fn void emit_casc_start(Output* out, int ind, Instr* ins) {
    Cascade* ca = &cascades[ins.a];
    assert(ins.a >= 0);
    assert(ins.a < (int)cascades.len());
    assert(ca.med_count > 0);
    assert(ca.med_count <= CASC_MED_MAX);
    assert(ca.seq > 0);
    assert(ca.block >= 0);
    assert(ca.block < (int)blocks.len());
    assert(ca.out_cell >= 0);
    assert(ca.out_cell < (int)cells.len());
    assert(ca.out_frame >= 0);
    assert(ca.out_frame < (int)frames.len());
    assert(ca.name.len > 0);
    pad(out, ind);
    out.appendf("/* %s %s (line %d) */\n",
                ca.is_async ? "acasc" : "casc", ca.name, ca.line);
    pad(out, ind);
    out.append_string("{\n");
    ind++;
    for (int i = 0; i < ca.med_count; i++) {
        int mi = ca.med_idxs[i];
        assert(mi >= 0);
        assert(mi < (int)meds.len());
        assert(meds[mi].gen > 0);
        pad(out, ind);
        out.appendf("void *p_%s = rez_deref_cell(%s);\n",
                    meds[mi].name, meds[mi].cname);
    }
    for (int i = 0; i < ca.med_count; i++) {
        int mi = ca.med_idxs[i];
        pad(out, ind);
        out.appendf("if (!p_%s) {\n", meds[mi].name);
        pad(out, ind + 1);
        out.appendf("fprintf(stderr, \"ABORT line %d: cascade %s: "
                    "dead mediator %s\\n\");\n", ca.line, ca.name, meds[mi].name);
        pad(out, ind + 1);
        out.appendf("goto casc_end_%d;\n", ca.seq);
        pad(out, ind);
        out.append_string("}\n");
    }
    if (ca.out_cell < 0) return;
    pad(out, ind);
    out.appendf("%s = rez_cell_z(%s, 8);\n",
                cells[ca.out_cell].cname, fexpr(ca.out_frame));
    pad(out, ind);
    out.appendf("if (!%s) {\n", cells[ca.out_cell].cname);
    pad(out, ind + 1);
    out.appendf("fprintf(stderr, \"FAULT line %d: arena overflow (out %s)\\n\");\n",
                ca.line, cells[ca.out_cell].name);
    pad(out, ind + 1);
    out.append_string("exit(1);\n");
    pad(out, ind);
    out.append_string("}\n");
    emit_hoisted_meds(out, ind, ca.out_cell);
}

fn void emit_casc_end(Output* out, int ind, Instr* ins) {
    Cascade* ca = &cascades[ins.a];
    assert(ins.a >= 0);
    assert(ins.a < (int)cascades.len());
    assert(ca.seq > 0);
    assert(ca.block >= 0);
    assert(ca.block < (int)blocks.len());
    assert(ca.name.len > 0);
    pad(out, ind);
    out.appendf("casc_end_%d:\n", ca.seq);
    pad(out, ind + 1);
    out.append_string("(void)0;\n");
    pad(out, ind);
    out.append_string("}\n");
}

fn void emit_body(Output* out, int func) {
    int ind = 1;
    assert(func <= (int)procs.len());
    for (sz i = 0; i < instrs.len(); i++) {
        Instr* ins = &instrs[i];
        if (ins.func != func) continue;
        assert(ins.line > 0);
        assert(ins.block < (int)blocks.len());
        bool in_casc = blocks[ins.block].kind == 2;
        switch (ins.op) {
            case Op.LABEL:
                emit_label(out, ind, ins);
            case Op.CAV: case Op.RES: case Op.MED:
            case Op.RAISE: case Op.DECAY: case Op.PROBE:
                emit_own(out, ind, ins);
            case Op.CASC:
                emit_casc_start(out, ind, ins);
                ind++;
            case Op.ENDC:
                ind--;
                emit_casc_end(out, ind, ins);
            case Op.LOAD:
                emit_load(out, ind, ins, in_casc);
            case Op.STORE:
                emit_store(out, ind, ins, in_casc);
            case Op.MOV:
                pad(out, ind);
                if (ins.flag) {
                    out.appendf("r%d = %d;\n", ins.a, ins.b);
                } else {
                    out.appendf("r%d = r%d;\n", ins.a, ins.b);
                }
            case Op.ALU3:
                emit_alu3(out, ind, ins);
            case Op.ALU1:
                pad(out, ind);
                out.appendf("r%d = %s(r%d, 1);\n", ins.a,
                            ins.flag ? "rez_i64_add" : "rez_i64_sub", ins.a);
            case Op.PRINT:
                pad(out, ind);
                out.appendf("printf(\"%%lld\\n\", (long long)r%d);\n", ins.a);
            case Op.JMP:
                pad(out, ind);
                out.appendf("goto %s;\n", label_cname(ins.block, ins.s1));
            case Op.BRZ:
                pad(out, ind);
                out.appendf("if (r%d == 0) goto %s;\n",
                            ins.a, label_cname(ins.block, ins.s1));
            case Op.BRNZ:
                pad(out, ind);
                out.appendf("if (r%d != 0) goto %s;\n",
                            ins.a, label_cname(ins.block, ins.s1));
            case Op.CALL:
                pad(out, ind);
                if (g_lib_mode) {
                    out.appendf("rza_%s();\n", procs[ins.x].name);
                } else {
                    out.appendf("%s();\n", procs[ins.x].cname);
                }
            case Op.RET:
                if (ins.func == 0) {
                    pad(out, ind);
                    // lib-режим: верхнеуровневый ret = конец rza_boot (void)
                    out.append_string(g_lib_mode ? "return;\n"
                                                 : "return 0;\n");
                }
                // ret процедуры: закрытие функции делает emit_proc
        }
    }
}

fn void emit_proc(Output* out, int pi) {
    Proc* p = &procs[pi];
    assert(pi >= 0);
    assert(pi < (int)procs.len());
    assert(p.frame >= 0);
    assert(p.frame < (int)frames.len());
    assert(p.block >= 0);
    assert(p.block < (int)blocks.len());
    assert(p.line > 0);
    assert(p.cname.len > 0);
    assert(frames[p.frame].is_procframe);
    assert(frames[p.frame].cap <= ARENA_FRAME_MAX);
    if (g_lib_mode) {
        out.appendf("void rza_%s(void) {\n", p.name);
    } else {
        out.appendf("[[maybe_unused]] static void %s(void) {\n", p.cname);
    }
    uint rd, wr;
    scan_regs(pi + 1, &rd, &wr);
    emit_regs_decl(out, 1, rd | wr);
    out.appendf("    if (!rez_frame_reset(&%s, f_field, A_%s, %d)) {\n"
                "        fprintf(stderr, \"FAULT line %d: frame allocation %s\\n\");\n"
                "        exit(1);\n"
                "    }\n",
                frames[p.frame].cname, frames[p.frame].cname,
                frames[p.frame].cap, p.line, p.name);
    emit_body(out, pi + 1);
    emit_writeonly_silence(out, 1, rd, wr);
    emit_decay_subtree(out, 1, p.frame);
    out.appendf("    rez_decay(&%s);\n", frames[p.frame].cname);
    out.append_string("}\n");
}

fn void emit_main(Output* out) {
    out.append_string("int main(void) {\n");
    uint rd, wr;
    scan_regs(0, &rd, &wr);
    assert(frames[0].is_field);
    assert(frames[0].cap >= 64);
    assert(frames[0].cap <= ARENA_FRAME_MAX);
    assert(rd <= 0xFFFF);
    assert(wr <= 0xFFFF);
    emit_regs_decl(out, 1, rd | wr);
    out.appendf("    if (!rez_frame_reset(f_field, nullptr, A_field, %d)) {\n"
                "        fprintf(stderr, \"FAULT line 0: frame allocation field\\n\");\n"
                "        exit(1);\n"
                "    }\n", frames[0].cap);
    emit_body(out, 0);
    emit_writeonly_silence(out, 1, rd, wr);
    bool last_ret = false;
    for (sz i = instrs.len(); i > 0; i--) {
        if (instrs[i - 1].func == 0) {
            last_ret = instrs[i - 1].op == Op.RET;
            break;
        }
    }
    if (!last_ret) out.append_string("    return 0;\n");
    out.append_string("}\n");
}

fn void emit_boot(Output* out) {
    out.append_string("void rza_boot(void) {\n");
    uint rd, wr;
    scan_regs(0, &rd, &wr);
    assert(frames[0].is_field);
    assert(frames[0].cap >= 64);
    assert(frames[0].cap <= ARENA_FRAME_MAX);
    assert(rd <= 0xFFFF);
    assert(wr <= 0xFFFF);
    emit_regs_decl(out, 1, rd | wr);
    out.appendf("    if (!rez_frame_reset(f_field, nullptr, A_field, %d)) {\n"
                "        fprintf(stderr, \"FAULT line 0: frame allocation field\\n\");\n"
                "        exit(1);\n"
                "    }\n", frames[0].cap);
    emit_body(out, 0);
    emit_writeonly_silence(out, 1, rd, wr);
    out.append_string("}\n");
}

fn void emit_host_api(Output* out) {
    assert(g_lib_mode);
    assert(frames.len() <= NODE_MAX);
    assert(meds.len() <= NODE_MAX);
    out.append_string("\n/* Host API: frames, mediators, and arena. */\n");
    for (sz i = 0; i < frames.len(); i++) {
        assert(frames[i].name.len > 0);
        assert(frames[i].cname.len > 0);
        assert(frames[i].scope >= 0);
        out.appendf("RezCavity *rza_frame_%s(void) { return %s; }\n",
                    frames[i].name, fexpr((int)i));
    }
    for (sz i = 0; i < meds.len(); i++) {
        int ci = meds[i].cell;
        assert(ci >= 0);
        assert(ci < (int)cells.len());
        assert(meds[i].name.len > 0);
        assert(meds[i].gen > 0);
        out.appendf("RezCellMed rza_med_%s(void) {\n", meds[i].name);
        out.appendf("    if (!%s.cell) {\n", meds[i].cname);
        out.appendf("        %s = rez_issue_cell(\n", meds[i].cname);
        out.appendf("            %s, %s, %s, %d\n",
                    fexpr(cells[ci].owner), fexpr(cells[ci].home),
                    cells[ci].cname, cells[ci].size);
        out.appendf("        );\n");
        out.append_string("    }\n");
        out.appendf("    return %s;\n", meds[i].cname);
        out.append_string("}\n");
    }
    out.append_string("uint32_t rza_rez3ext_abi(void) { return REZ3EXT_ABI; }\n");
    out.append_string("void *rza_arena_alloc(RezCavity *cavity, uint64_t size) "
                      "{ return rez_cell_z(cavity, size); }\n");
    out.append_string("void *rza_deref_cell(RezCellMed mediator) "
                      "{ return rez_deref_cell(mediator); }\n");
}

fn void emit_static_storage(Output* out) {
    out.append_string("static RezCavity S_field;\n");
    out.append_string("static RezCavity *f_field = &S_field;\n");
    out.appendf("static char A_field[%d];\n", frames[0].cap);
    for (sz i = 0; i < frames.len(); i++) {
        assert(frames[i].cname.len > 0);
        assert(frames[i].cap >= 64);
        assert(frames[i].cap <= ARENA_FRAME_MAX);
        assert(frames[i].scope >= 0);
        if (frames[i].scope == 0 && !frames[i].is_field) {
            out.appendf("static RezCavity S_%s;\n", frames[i].cname);
            out.appendf("static RezCavity *%s = &S_%s;\n",
                        frames[i].cname, frames[i].cname);
            out.appendf("static char A_%s[%d];\n",
                        frames[i].cname, frames[i].cap);
        }
    }
    for (sz i = 0; i < cells.len(); i++) {
        assert(cells[i].owner >= 0);
        assert(cells[i].owner < (int)frames.len());
        assert(cells[i].home >= 0);
        assert(cells[i].home < (int)frames.len());
        if (cells[i].scope == 0) {
            out.appendf("static void *%s;\n", cells[i].cname);
        }
    }
    for (sz i = 0; i < meds.len(); i++) {
        assert(meds[i].cell >= 0);
        assert(meds[i].cell < (int)cells.len());
        assert(meds[i].cname.len > 0);
        assert(meds[i].gen > 0);
        if (meds[i].scope == 0) {
            out.appendf("static RezCellMed %s;\n", meds[i].cname);
        }
    }
    for (sz i = 0; i < procs.len(); i++) {
        assert(procs[i].frame >= 0);
        assert(procs[i].frame < (int)frames.len());
        assert(procs[i].block >= 0);
        assert(procs[i].block < (int)blocks.len());
        assert(procs[i].cname.len > 0);
        out.appendf("static RezCavity %s;\n", frames[procs[i].frame].cname);
        out.appendf("static char A_%s[%d];\n",
                    frames[procs[i].frame].cname, frames[procs[i].frame].cap);
        int pscope = (int)i + 1;
        for (sz j = 0; j < frames.len(); j++) {
            if (frames[j].scope == pscope && !frames[j].is_procframe) {
                out.appendf("static RezCavity S_%s;\n", frames[j].cname);
                out.appendf("static RezCavity *%s = &S_%s;\n",
                            frames[j].cname, frames[j].cname);
                out.appendf("static char A_%s[%d];\n",
                            frames[j].cname, frames[j].cap);
            }
        }
        for (sz j = 0; j < cells.len(); j++) {
            if (cells[j].scope == pscope) {
                out.appendf("static void *%s;\n", cells[j].cname);
            }
        }
        for (sz j = 0; j < meds.len(); j++) {
            assert(meds[j].cell >= 0);
            assert(meds[j].cell < (int)cells.len());
            assert(meds[j].gen > 0);
            if (meds[j].scope == pscope) {
                out.appendf("static RezCellMed %s;\n", meds[j].cname);
            }
        }
    }
    out.append_string("\n");
}

fn String emit() {
    assert(violations == 0);
    assert(frames.len() > 0);
    assert(frames[0].is_field);
    Output out;
    out.init(8192, OUTPUT_BYTES_MAX);
    assert(frames.len() <= NODE_MAX);
    assert(cells.len() <= NODE_MAX);
    assert(meds.len() <= NODE_MAX);
    assert(procs.len() <= NODE_MAX);
    assert(cascades.len() <= NODE_MAX);
    assert(blocks.len() <= NODE_MAX);
    assert(labels.len() <= NODE_MAX);
    assert(instrs.len() <= NODE_MAX);
    assert(out.max_bytes == OUTPUT_BYTES_MAX);
    assert(out.text.len() == 0);
    assert(srcname.len > 0);
    out.appendf("/* Generated by rez3asm (C3) from %s — REZ3-ASM -> C23 */\n",
                srcname);
    out.append_string("#include <stdio.h>\n");
    out.append_string("#include <stdint.h>\n");
    out.append_string("#include <stdlib.h>\n");
    out.append_string("#include \"rez3ext.h\"\n\n");
    emit_static_storage(&out);
    for (sz i = 0; i < procs.len(); i++) {
        if (g_lib_mode) {
            out.appendf("void rza_%s(void);\n", procs[i].name);
        } else {
            out.appendf("[[maybe_unused]] static void %s(void);\n", procs[i].cname);
        }
    }
    if (procs.len() > 0) out.append_string("\n");
    for (sz i = 0; i < procs.len(); i++) {
        emit_proc(&out, (int)i);
        out.append_string("\n");
    }
    if (g_lib_mode) {
        emit_boot(&out);
        emit_host_api(&out);
    } else {
        emit_main(&out);
    }
    out.append_string("\n");
    if (out.overflow) {
        viol(0, "STRUCT", "generated C exceeds static budget");
        return "";
    }
    return out.str_view();
}
