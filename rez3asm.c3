// ============================================================================
// rez3asm.c3 — транспайлер REZ3-ASM (.rza) -> C99 (rez3.h + rez3ext.h).
// Порт rez3asm.py (Python 3) на C3 0.8.5, функциональный паритет 1:1.
//
// CLI:
//   rez3asm file.rza                    только статическая проверка
//   rez3asm file.rza --emit-c           C99 (программа с main) на stdout
//   rez3asm file.rza --emit-lib         C99-библиотека без main: proc →
//                                       rza_NAME, верхний уровень → rza_boot
//   rez3asm file.rza --emit-c -o f.c    C99 в файл
//   rez3asm --lsp                       LSP-сервер на stdio (lsp_server.c3)
//
// Один проход: разбор + I1..I4, DECAY, DUP, STRUCT, SCOPE. Все нарушения — в
// stderr: "VIOLATION line N [RULE]: msg"; exit 1, если есть хотя бы одно
// (код тогда не генерируется). Метки/переходы добираются вторым проходом
// по уже разобранным инструкциям (проверка инвариантов однопроходная).
// Нормативно (AUDIT-1/#3): load/store по статически мёртвому медиатору —
// не violation, а runtime-fault в сгенерированном коде.
// ============================================================================
module rez3asm;

import std::io;
import std::io::file;
import std::core::dstring;
import std::collections::list;
import std::collections::map;

// --- модель ------------------------------------------------------------------
struct Frame {
    String name;
    int    parent;        // индекс в frames, -1 = нет
    bool   alive;
    uint   gen;
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
    int    owner;         // индекс Frame
    String cname;
    int    scope;
    bool   is_out;
    List{int} med_idxs;
}

struct Med {
    String name;
    int    cell;          // индекс Cell
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
    List{int}    med_idxs;
    List{String} med_names;
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

// --- глобальное состояние ------------------------------------------------------
List{Frame}   frames;
List{Cell}    cells;
List{Med}     meds;
List{Proc}    procs;
List{Cascade} cascades;
List{Block}   blocks;
List{LabelDef} labels;
List{Instr}   instrs;
HashMap{String, int} frame_map;
HashMap{String, int} cell_map;
HashMap{String, int} med_map;
HashMap{String, int} proc_map;
HashMap{String, int} label_map;
HashMap{String, bool} label_names;

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
bool g_lib_mode = false;   // --emit-lib: C99 без main, proc → rza_NAME
String srcname;

bool g_state_inited = false;

// полный сброс состояния чекера: CLI зовёт один раз, LSP — на каждую
// валидацию (документ проверяется целиком, Full sync)
fn void reset_state() {
    if (!g_state_inited) {
        frames.init(mem);
        cells.init(mem);
        meds.init(mem);
        procs.init(mem);
        cascades.init(mem);
        blocks.init(mem);
        labels.init(mem);
        instrs.init(mem);
        lsp_diags.init(mem);
        frame_map.init(mem);
        cell_map.init(mem);
        med_map.init(mem);
        proc_map.init(mem);
        label_map.init(mem);
        label_names.init(mem);
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
    frames.push({ .name = "field", .parent = -1, .alive = true,
                  .gen = nextgen(), .cname = "f_field", .scope = 0,
                  .cap = 64, .is_field = true });
    frame_map.set("field", 0);
}

// --- утилиты -------------------------------------------------------------------
fn uint nextgen() { uint g = gencnt; gencnt++; return g; }

fn String cat(String[] parts) {
    DString d = dstring::new_with_capacity(tmem, 64);
    foreach (p : parts) d.append_string(p);
    return d.copy_str(tmem);
}

fn void viol(int line, String rule, String msg) {
    violations++;
    if (g_lsp_mode) {
        lsp_diags.push({ .line = line, .rule = rule, .msg = msg });
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

// число: dec или 0x-hex (AUDIT-5: hex для asm-стиля); вызывающий обязан
// проверить is_int заранее
fn int parse_num(String s) {
    bool neg = s[0] == '-';
    usz i = (usz)(neg ? 1 : 0);
    int v = 0;
    if (s.len > i + 2 && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
        for (usz j = i + 2; j < s.len; j++) {
            char c = s[j];
            int d = (c <= '9') ? c - '0'
                  : (c <= 'F' ? c - 'A' + 10 : c - 'a' + 10);
            v = v * 16 + d;
        }
    } else {
        for (; i < s.len; i++) { v = v * 10 + (s[i] - '0'); }
    }
    return neg ? -v : v;
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
    int? fi = frame_map.get(name);
    if (catch fi) return -1;
    return frames[fi].scope == 0 || frames[fi].scope == scope ? fi : -1;
}

fn int find_cell(String name, int scope) {
    int? ci = cell_map.get(name);
    if (catch ci) return -1;
    return cells[ci].scope == 0 || cells[ci].scope == scope ? ci : -1;
}

fn int find_med(String name, int scope) {
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

// review-audit: host API lib-режима (SPEC 11) эмитит rza_<proc>, rza_boot,
// rza_arena_alloc, rza_deref_cell и геттеры rza_frame_<рамка> /
// rza_med_<медиатор> для КАЖДОЙ сущности. Проверки — всегда, не только
// при --emit-lib: ошибка должна ловиться чекером, а не компилятором C.
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

fn void kill(int f) {
    frames[f].alive = false;
    frames[f].gen = nextgen();
    for (sz i = 0; i < frames.len(); i++) {
        if (frames[i].alive && frames[i].parent == f) kill((int)i);
    }
}

// --- блоки -----------------------------------------------------------------------
fn int cur_block() {
    if (cur_casc >= 0) return cascades[cur_casc].block;
    if (cur_proc > 0) return procs[(sz)(cur_proc - 1)].block;
    return 0;
}

fn int cur_func() { return cur_proc; }   // 0 = main

fn void add_instr(Instr ins) {
    ins.func = cur_func();
    ins.block = cur_block();
    instrs.push(ins);
}

fn String label_key(int block, String name) {
    DString key = dstring::new_with_capacity(tmem, name.len + 16);
    key.appendf("%d:%s", block, name);
    return key.str_view();
}

fn void add_label(String name, int line) {
    int bid = cur_block();
    if (label_map.has_key(label_key(bid, name))) {
        viol(line, "DUP", cat({"duplicate label ", name}));
        return;
    }
    labels.push({ .name = name, .line = line, .block = bid, .referenced = false });
    label_map.set(label_key(bid, name), (int)labels.len() - 1);
    label_names.set(name, true);
    Instr ins = { .op = Op.LABEL, .line = line, .s1 = name };
    add_instr(ins);
}

// --- операции владения -------------------------------------------------------------
// C-имя сущности. Склейка scope'а — заглавными разделителями («P_» + proc +
// «X» + имя): имена языка только строчные, поэтому коллизия склеенного имени
// с верхнеуровневым невозможна (review #3: «cav proc_k» vs «proc k»,
// «cav k_a» vs «cav a» внутри «proc k» — раньше молча сливались).
fn String cname_for(String prefix, String name) {
    return cur_proc > 0 ? cat({prefix, "P_", procs[(sz)(cur_proc - 1)].name,
                               "X", name})
                        : cat({prefix, name});
}

fn void op_cav(String rest, int line) {
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
    // review-audit: proc уже создал рамку со своим именем (scope > 0,
    // check_dup её не видит) — два rza_frame_<name> в lib-режиме
    if (find_proc(name) >= 0) {
        viol(line, "DUP", cat({"frame shadows procedure ", name}));
        return;
    }
    // AUDIT-3: рамки — общая хроника (scope 0), даже когда созданы в proc
    Frame f = { .name = name, .parent = pf, .alive = true, .gen = nextgen(),
                .cname = cname_for("f_", name), .scope = 0, .cap = 64 };
    frames.push(f);
    frame_map.set(name, (int)frames.len() - 1);
    add_instr({ .op = Op.CAV, .line = line, .x = (int)frames.len() - 1, .y = pf });
}

fn void op_res(String rest, int line) {
    String[3] buf;
    if (!split_ops_exact(rest, 3, line, "res", &buf)) return;
    String name = buf[0];
    String fname = buf[1];
    String ssize = buf[2];
    if (!check_name(name, line)) return;
    // размер — как imm у mov (AUDIT-4): не i32 или не число — violation,
    // а не молчаливый 0 (review #6: «нет молчаливой неправильности»)
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
    if (!check_dup(name, line, 0)) return;
    // AUDIT-3: ячейки — общая хроника (scope 0)
    Cell cc = { .name = name, .owner = f, .cname = cname_for("c_", name),
                .scope = 0 };
    cc.med_idxs.init(tmem);
    cells.push(cc);
    cell_map.set(name, (int)cells.len() - 1);
    frames[f].res_bytes += (size + 15) & ~15;
    add_instr({ .op = Op.RES, .line = line, .x = (int)cells.len() - 1,
                .y = f, .a = size });
}

fn void op_med(String rest, int line) {
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
    // review-audit: lib-режим экспортирует геттер rza_med_<name> для
    // КАЖДОГО медиатора — имя уникально глобально, не только в scope
    if (med_map.has_key(name)) {
        viol(line, "DUP", cat({"duplicate mediator ", name,
             " (host API exports every mediator, SPEC 11)"}));
        return;
    }
    Med m = { .name = name, .cell = ci, .gen = frames[cells[ci].owner].gen,
              .cname = cname_for("m_", name), .scope = cur_proc };
    meds.push(m);
    int mi = (int)meds.len() - 1;
    med_map.set(name, mi);
    cells[ci].med_idxs.push(mi);
    add_instr({ .op = Op.MED, .line = line, .x = mi });
}

fn void op_raise(String rest, int line) {
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
    cells[ci].owner = f;   // опора переприбита; старые медиаторы мертвы (gen)
    add_instr({ .op = Op.RAISE, .line = line, .x = ci, .y = f });
}

fn void op_decay(String rest, int line) {
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
                // review-audit: та же норма, что у imm у mov — вне i32
                // violation, а не молчаливый wrap
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
    if (cur_casc >= 0) {
        bool ok = false;
        foreach (mn : cascades[cur_casc].med_names) {
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
                    .b = parse_num(buf[1]), .flag = true });
        return;
    }
    int src = parse_reg(buf[1], line);
    if (src < 0) return;
    add_instr({ .op = Op.MOV, .line = line, .a = dst, .b = src, .flag = false });
}

fn void op_alu3(String opname, String coper, String rest, int line) {
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
    String[1] buf;
    if (!split_ops_exact(rest, 1, line, "print", &buf)) return;
    int r = parse_reg(buf[0], line);
    if (r < 0) return;
    add_instr({ .op = Op.PRINT, .line = line, .a = r });
}

fn void op_jmp(String rest, int line) {
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
    blocks.push({ .kind = 1, .aux = (int)procs.len() });
    Frame f = { .name = name, .parent = 0, .alive = true, .gen = nextgen(),
                .cname = cat({"f_P_", name}), .scope = (int)procs.len() + 1,
                .cap = 64, .is_procframe = true };
    frames.push(f);
    frame_map.set(name, (int)frames.len() - 1);
    Proc p = { .name = name, .line = line, .frame = (int)frames.len() - 1,
               .block = (int)blocks.len() - 1, .cname = cat({"p_", name}) };
    procs.push(p);
    proc_map.set(name, (int)procs.len() - 1);
    cur_proc = (int)procs.len();   // 1-based
}

fn void do_ret(int line) {
    if (cur_proc > 0) {
        add_instr({ .op = Op.RET, .line = line });
        // ret разрушает рамку процедуры (runtime: rez_decay в emit_proc) —
        // чекер обязан видеть её и всё поддерево мёртвыми, иначе медиаторы
        // на её ячейки проходят I3 и абортируют каскады в runtime
        // (AUDIT-7, review #7)
        kill(procs[(sz)(cur_proc - 1)].frame);
        cur_proc = 0;
        return;
    }
    add_instr({ .op = Op.RET, .line = line });
    if (top_ret == 0) top_ret = line;
}

fn void open_casc(String rest, int line, bool is_async) {
    // rest: "NAME: M1,M2 -> OUT[CAV]"  (acasc: без [CAV])
    sz? ci = rest.index_of_char(':');
    if (catch ci) { viol(line, "STRUCT", "malformed cascade header"); return; }
    String name = rest[:ci].trim();
    String r2 = rest[ci + 1..];
    sz? ai = r2.index_of("->");
    if (catch ai) { viol(line, "STRUCT", "malformed cascade header"); return; }
    String medstr = r2[:ai].trim();
    String outstr = r2[ai + 2..].trim();
    if (!check_name(name, line)) return;
    String outname = outstr;
    String outfname = "";
    sz? bi = outstr.index_of_char('[');
    if (try bi) {
        sz? ei = outstr.index_of_char(']');
        if (catch ei) {
            viol(line, "STRUCT", "malformed cascade header"); return;
        }
        if (ei <= bi + 1 || ei != outstr.len - 1) {
            viol(line, "STRUCT", "malformed cascade header"); return;
        }
        outname = outstr[:bi].trim();
        outfname = outstr[bi + 1..ei - 1].trim();
    }
    if (is_async && outfname.len > 0) {
        viol(line, "STRUCT", "acasc out frame is implicit (always field)");
    }
    // входные медиаторы
    List{int} med_idxs; med_idxs.init(mem);
    List{String} med_names; med_names.init(mem);
    if (medstr.len == 0) {
        viol(line, "STRUCT", cat({"cascade ", name, " without input mediators"}));
    }
    String ms = medstr;
    while (ms.len > 0) {
        sz? mi2 = ms.index_of_char(',');
        String tok;
        if (catch mi2) { tok = ms.trim(); ms = ""; }
        else { tok = ms[:mi2].trim(); ms = ms[mi2 + 1..]; }
        if (tok.len == 0) continue;
        if (!check_name(tok, line)) continue;
        int mdi = find_med(tok, cur_proc);
        if (mdi == -2) { scope_viol(line, "mediator", tok); continue; }
        if (mdi < 0) {
            viol(line, "I3", cat({"cascade uses unknown link ", name, " ", tok}));
            continue;
        }
        foreach (prev : med_names) {
            if (prev == meds[mdi].name) {
                viol(line, "DUP", cat({"cascade ", name,
                     ": duplicate input link ", tok}));
            }
        }
        med_idxs.push(mdi);
        med_names.push(meds[mdi].name);
        if (is_async) {
            if (!frames[cells[meds[mdi].cell].owner].is_field) {
                viol(line, "I3", cat({"async cascade holds non-root link ",
                                      name, " ", tok}));
            }
        } else {
            if (!med_alive(mdi)) {
                viol(line, "I3",
                     cat({"sync cascade aborted: dead link on entry ",
                          name, " ", tok}));
            }
        }
    }
    // OUT — всегда НОВАЯ ячейка (AUDIT-1/#6); для acasc — в field (#7)
    int out_cell = -1;
    int out_frame = -1;
    if (check_name(outname, line) && check_dup(outname, line, 0)) {
        if (is_async) {
            out_frame = 0;
        } else {
            int of = find_frame(outfname, cur_proc);
            if (of < 0) {
                viol(line, "I3", cat({"out cell in unknown frame ",
                                      outname, " ", outfname}));
            }
            else { out_frame = of; }
        }
        if (out_frame >= 0) {
            if (!frames[out_frame].alive) {
                viol(line, "I1", cat({"cell in dead frame ", outname, " ",
                                      frames[out_frame].name}));
            }
            Cell oc = { .name = outname, .owner = out_frame,
                        .cname = cname_for("c_", outname),
                        .scope = 0, .is_out = true };
            oc.med_idxs.init(tmem);
            cells.push(oc);
            cell_map.set(outname, (int)cells.len() - 1);
            out_cell = (int)cells.len() - 1;
            frames[out_frame].outs += 1;
        }
    }
    casc_seq++;
    blocks.push({ .kind = 2, .aux = casc_seq });
    Cascade ca = { .name = name, .line = line, .seq = casc_seq,
                   .is_async = is_async, .block = (int)blocks.len() - 1,
                   .med_idxs = med_idxs, .med_names = med_names,
                   .out_cell = out_cell, .out_frame = out_frame };
    cascades.push(ca);
    cur_casc = (int)cascades.len() - 1;
    // заголовок принадлежит объемлющему блоку
    Instr ins = { .op = Op.CASC, .line = line, .a = cur_casc };
    ins.func = cur_func();
    ins.block = (cur_proc > 0) ? procs[(sz)(cur_proc - 1)].block : 0;
    instrs.push(ins);
}

fn void end_casc(int line) {
    Instr ins = { .op = Op.ENDC, .line = line, .a = cur_casc };
    ins.func = cur_func();
    ins.block = (cur_proc > 0) ? procs[(sz)(cur_proc - 1)].block : 0;
    instrs.push(ins);
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
fn void run(String text) {
    String[] lines = text.split(tmem, "\n");
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
            if (cur_proc > 0) {
                viol(n, "STRUCT", cat({"nested proc ", line[sp..].trim()}));
                continue;
            }
            String pnm = line[sp..].trim();
            if (pnm.len > 1 && pnm[pnm.len - 1] == ':') {
                pnm = pnm[:pnm.len - 1].trim();
            }
            if (!is_name(pnm)) {
                viol(n, "STRUCT", "malformed proc header");
                continue;
            }
            open_proc(pnm, n);
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

fn void compute_caps() {
    for (sz i = 0; i < frames.len(); i++) {
        int total = frames[i].res_bytes + 16 * frames[i].outs;
        frames[i].cap = total > 64 ? total : 64;
    }
}

// --- генерация C99 ------------------------------------------------------------------
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
            DString d = dstring::new_with_capacity(mem, 32);
            d.appendf("L_C%d_%s", b.aux, name);
            return d.copy_str(mem);
        }
    }
}

fn void pad(DString* out, int ind) {
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

fn void emit_regs_decl(DString* out, int ind, uint mask) {
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

fn void emit_writeonly_silence(DString* out, int ind, uint rd, uint wr) {
    for (int r = 0; r < 16; r++) {
        if ((wr & (1u << r)) != 0 && (rd & (1u << r)) == 0) {
            pad(out, ind);
            out.appendf("(void)r%d;\n", r);
        }
    }
}

// верхнеуровневые медиаторы на ячейку cell инициализируются сразу после
// её создания (AUDIT-4): ячейка может создаваться внутри proc (lib), и
// тогда текстовая позиция med — мимо. Общий случай — res и OUT-ячейка
// каскада (review #2: для OUT подъёма не было — медиатор оставался
// нулевым, runtime FAULT)
fn void emit_hoisted_meds(DString* out, int ind, int cell, int owner) {
    foreach (mi : cells[cell].med_idxs) {
        if (meds[mi].scope != 0) continue;
        pad(out, ind);
        out.appendf("%s = rez_issue_cell(%s, %s);\n",
                    meds[mi].cname, fexpr(owner), cells[cell].cname);
    }
}

// decay убивает поддерево рекурсивно (модель §0) — как чекер kill();
// раньше runtime гасил только саму рамку (review #1). rez_decay
// идемпотентен (после первого вызова arena.base = 0, free(0) безвреден);
// guard — потомок мог не создаться в этом проходе (proc не вызывался,
// переход через cav)
fn void emit_decay_subtree(DString* out, int ind, int f) {
    for (sz i = 0; i < frames.len(); i++) {
        if (frames[i].is_field || frames[i].is_procframe) continue;
        if (!is_ancestor((int)i, f, true)) continue;
        pad(out, ind);
        out.appendf("if (%s) rez_decay(%s);\n",
                    frames[i].cname, frames[i].cname);
    }
}

fn void emit_body(DString* out, int func) {
    int ind = 1;
    for (sz i = 0; i < instrs.len(); i++) {
        Instr* ins = &instrs[i];
        if (ins.func != func) continue;
        bool in_casc = blocks[ins.block].kind == 2;
        switch (ins.op) {
            case Op.LABEL: {
                // печатаем только метки-цели переходов (иначе -Wunused-label)
                for (sz j = 0; j < labels.len(); j++) {
                    if (labels[j].block == ins.block && labels[j].name == ins.s1) {
                        if (labels[j].referenced) {
                            pad(out, ind);
                            out.appendf("%s:\n", label_cname(ins.block, ins.s1));
                        }
                        break;
                    }
                }
            }
            case Op.CAV:
                pad(out, ind);
                out.appendf("%s = rez_enter(%s, %d);\n",
                            frames[ins.x].cname, fexpr(ins.y),
                            frames[ins.x].cap);
            case Op.RES:
                pad(out, ind);
                out.appendf("%s = rez_cell_z(%s, %d);\n",
                            cells[ins.x].cname, fexpr(ins.y), ins.a);
                pad(out, ind);
                out.appendf("if (!%s) { fprintf(stderr, \"FAULT line %d: "
                            "arena overflow (cell %s)\\n\"); exit(1); }\n",
                            cells[ins.x].cname, ins.line, cells[ins.x].name);
                emit_hoisted_meds(out, ind, ins.x, ins.y);
            case Op.MED:
                // верхнеуровневые медиаторы инициализируются при создании
                // ячейки (см. Op.RES), а не по текстовой позиции (AUDIT-4)
                if (ins.func == 0) break;
                pad(out, ind);
                out.appendf("%s = rez_issue_cell(%s, %s);\n",
                            meds[ins.x].cname,
                            fexpr(cells[meds[ins.x].cell].owner),
                            cells[meds[ins.x].cell].cname);
            case Op.RAISE:
                pad(out, ind);
                out.appendf("/* raise %s -> %s (line %d): static-only, "
                            "no code (SPEC 9) */\n",
                            cells[ins.x].name, frames[ins.y].name, ins.line);
            case Op.DECAY:
                emit_decay_subtree(out, ind, ins.x);
                pad(out, ind);
                out.appendf("rez_decay(%s);\n", fexpr(ins.x));
            case Op.PROBE:
                pad(out, ind);
                out.appendf("printf(\"%%s\\n\", rez_deref_cell(%s) ? "
                            "\"ALIVE\" : \"DEAD\");\n", meds[ins.x].cname);
            case Op.CASC: {
                Cascade* ca = &cascades[ins.a];
                pad(out, ind);
                out.appendf("/* %s %s (line %d) */\n",
                            ca.is_async ? "acasc" : "casc", ca.name, ca.line);
                pad(out, ind);
                out.append_string("{\n");
                ind++;
                foreach (mi : ca.med_idxs) {
                    pad(out, ind);
                    out.appendf("void *p_%s = rez_deref_cell(%s);\n",
                                meds[mi].name, meds[mi].cname);
                }
                foreach (mi : ca.med_idxs) {
                    pad(out, ind);
                    out.appendf("if (!p_%s) { fprintf(stderr, \"ABORT line %d: "
                                "cascade %s: dead mediator %s\\n\"); "
                                "goto casc_end_%d; }\n",
                                meds[mi].name, ca.line, ca.name,
                                meds[mi].name, ca.seq);
                }
                if (ca.out_cell >= 0) {
                    pad(out, ind);
                    out.appendf("%s = rez_cell_z(%s, 8);\n",
                                cells[ca.out_cell].cname, fexpr(ca.out_frame));
                    pad(out, ind);
                    out.appendf("if (!%s) { fprintf(stderr, \"FAULT line %d: "
                                "arena overflow (out %s)\\n\"); exit(1); }\n",
                                cells[ca.out_cell].cname, ca.line,
                                cells[ca.out_cell].name);
                    emit_hoisted_meds(out, ind, ca.out_cell, ca.out_frame);
                }
            }
            case Op.ENDC: {
                Cascade* ca = &cascades[ins.a];
                ind--;
                pad(out, ind);
                out.appendf("casc_end_%d:\n", ca.seq);
                pad(out, ind + 1);
                out.append_string("(void)0;\n");
                pad(out, ind);
                out.append_string("}\n");
            }
            case Op.LOAD:
                DString oex = dstring::new(mem);
                defer oex.free();
                if (ins.c >= 0) { oex.appendf("r%d", ins.c); }
                else { oex.appendf("%d", ins.b); }
                if (in_casc) {
                    pad(out, ind);
                    if (ins.flag) {
                        out.appendf("r%d = (int64_t)*(unsigned char*)((char*)p_%s + %s);\n",
                                    ins.a, meds[ins.x].name, oex.str_view());
                    } else {
                        out.appendf("memcpy(&r%d, (char*)p_%s + %s, 8);\n",
                                    ins.a, meds[ins.x].name, oex.str_view());
                    }
                } else {
                    pad(out, ind);
                    out.appendf("{ void *p = rez_deref_cell(%s);\n",
                                meds[ins.x].cname);
                    pad(out, ind);
                    out.appendf("  if (!p) { fprintf(stderr, \"FAULT line %d: "
                                "dead mediator %s\\n\"); exit(1); }\n",
                                ins.line, meds[ins.x].name);
                    pad(out, ind);
                    if (ins.flag) {
                        out.appendf("  r%d = (int64_t)*(unsigned char*)((char*)p + %s); }\n",
                                    ins.a, oex.str_view());
                    } else {
                        out.appendf("  memcpy(&r%d, (char*)p + %s, 8); }\n",
                                    ins.a, oex.str_view());
                    }
                }
            case Op.STORE:
                DString sex = dstring::new(mem);
                defer sex.free();
                if (ins.c >= 0) { sex.appendf("r%d", ins.c); }
                else { sex.appendf("%d", ins.b); }
                if (in_casc) {
                    pad(out, ind);
                    out.appendf("memcpy((char*)p_%s + %s, &r%d, 8);\n",
                                meds[ins.x].name, sex.str_view(), ins.a);
                } else {
                    pad(out, ind);
                    out.appendf("{ void *p = rez_deref_cell(%s);\n",
                                meds[ins.x].cname);
                    pad(out, ind);
                    out.appendf("  if (!p) { fprintf(stderr, \"FAULT line %d: "
                                "dead mediator %s\\n\"); exit(1); }\n",
                                ins.line, meds[ins.x].name);
                    pad(out, ind);
                    out.appendf("  memcpy((char*)p + %s, &r%d, 8); }\n",
                                sex.str_view(), ins.a);
                }
            case Op.MOV:
                pad(out, ind);
                if (ins.flag) {
                    out.appendf("r%d = %d;\n", ins.a, ins.b);
                } else {
                    out.appendf("r%d = r%d;\n", ins.a, ins.b);
                }
            case Op.ALU3:
                pad(out, ind);
                if (ins.flag) {
                    out.appendf("r%d = r%d %s %d;\n", ins.a, ins.b,
                                ins.s2, ins.c);
                } else {
                    out.appendf("r%d = r%d %s r%d;\n", ins.a, ins.b,
                                ins.s2, ins.c);
                }
            case Op.ALU1:
                pad(out, ind);
                out.appendf("r%d%s;\n", ins.a, ins.flag ? "++" : "--");
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

fn void emit_proc(DString* out, int pi) {
    Proc* p = &procs[pi];
    // lib-режим: процедура — экспортируемая точка входа хоста
    if (g_lib_mode) {
        out.appendf("void rza_%s(void) {\n", p.name);
    } else {
        out.appendf("static void %s(void) {\n", p.cname);
    }
    uint rd, wr;
    scan_regs(pi + 1, &rd, &wr);
    emit_regs_decl(out, 1, rd | wr);
    out.appendf("    rez_frame_reset(&%s, f_field, %d);\n",
                frames[p.frame].cname, frames[p.frame].cap);
    emit_body(out, pi + 1);
    emit_writeonly_silence(out, 1, rd, wr);
    // ret разрушает рамку процедуры и всё поддерево (как kill в чекере,
    // AUDIT-7): рамки, созданные под ней в этом proc, гасим тоже
    emit_decay_subtree(out, 1, p.frame);
    out.appendf("    rez_decay(&%s);\n", frames[p.frame].cname);
    out.append_string("}\n");
}

// глушилка неиспользованных static-входов рантайма (адрес взят — warning-а нет)
fn void emit_silencers(DString* out) {
    bool used_cell = false;
    bool used_issue = false;
    bool used_deref = g_lib_mode;   // lib экспортирует rza_deref_cell
    bool used_decay = procs.len() > 0;
    for (sz i = 0; i < instrs.len(); i++) {
        switch (instrs[i].op) {
            case Op.RES: case Op.CASC: used_cell = true;
            case Op.MED: used_issue = true;
            case Op.PROBE: case Op.LOAD: case Op.STORE: used_deref = true;
            case Op.DECAY: used_decay = true;
            default: break;
        }
    }
    out.append_string("    /* unused runtime entries: адрес взят, warning-а нет */\n");
    out.append_string("    (void)&rez_issue;\n");
    out.append_string("    (void)&rez_deref;\n");
    if (!used_cell)  out.append_string("    (void)&rez_cell_z;\n");
    if (!used_issue) out.append_string("    (void)&rez_issue_cell;\n");
    if (!used_deref) out.append_string("    (void)&rez_deref_cell;\n");
    if (!used_decay) out.append_string("    (void)&rez_leave;\n");
    if (procs.len() == 0) out.append_string("    (void)&rez_frame_reset;\n");
    if (!g_lib_mode) {
        for (sz i = 0; i < procs.len(); i++) {
            if (!procs[i].called) {
                out.appendf("    (void)&%s;\n", procs[i].cname);
            }
        }
    }
}

fn void emit_main(DString* out) {
    out.append_string("int main(void) {\n");
    uint rd, wr;
    scan_regs(0, &rd, &wr);
    emit_regs_decl(out, 1, rd | wr);
    emit_silencers(out);
    out.appendf("    f_field = rez_enter(NULL, %d);\n", frames[0].cap);
    emit_body(out, 0);
    emit_writeonly_silence(out, 1, rd, wr);
    // хвост: return 0, если верхний уровень не кончается ret
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

// lib-режим: верхнеуровневый код — rza_boot (включая создание field)
fn void emit_boot(DString* out) {
    out.append_string("void rza_boot(void) {\n");
    uint rd, wr;
    scan_regs(0, &rd, &wr);
    emit_regs_decl(out, 1, rd | wr);
    emit_silencers(out);
    out.appendf("    f_field = rez_enter(NULL, %d);\n", frames[0].cap);
    emit_body(out, 0);
    emit_writeonly_silence(out, 1, rd, wr);
    out.append_string("}\n");
}

// lib-режим: геттеры для хоста (рамки, медиаторы) + обёртки над static-рантаймом
fn void emit_host_api(DString* out) {
    out.append_string("\n/* host API: рамки, медиаторы, арена */\n");
    for (sz i = 0; i < frames.len(); i++) {
        out.appendf("RezCavity *rza_frame_%s(void) { return %s; }\n",
                    frames[i].name, fexpr((int)i));
    }
    for (sz i = 0; i < meds.len(); i++) {
        // ленивая инициализация: в lib-режиме ячейка может создаваться proc'ом
        // позже rza_boot; при первом обращении медиатор довыдаётся (AUDIT-4)
        out.appendf("RezCellMed rza_med_%s(void) { "
                    "if (!%s.cell) %s = rez_issue_cell(%s, %s); return %s; }\n",
                    meds[i].name, meds[i].cname, meds[i].cname,
                    fexpr(cells[meds[i].cell].owner), cells[meds[i].cell].cname,
                    meds[i].cname);
    }
    out.append_string("unsigned rza_rez3ext_abi(void) { return REZ3EXT_ABI; }\n");
    out.append_string("void *rza_arena_alloc(RezCavity *c, size_t size) "
                      "{ void *p = rez_arena_alloc(&c->arena, size); "
                      "if (p) memset(p, 0, size); return p; }\n");
    out.append_string("void *rza_deref_cell(RezCellMed m) "
                      "{ return rez_deref_cell(m); }\n");
}

fn String emit() {
    DString out = dstring::new_with_capacity(mem, 8192);
    out.appendf("/* Generated by rez3asm (C3) from %s — REZ3-ASM -> C99 */\n",
                srcname);
    out.append_string("#include <stdio.h>\n");
    out.append_string("#include <stdint.h>\n");
    out.append_string("#include <stdlib.h>\n");
    out.append_string("#include \"rez3.h\"\n");
    out.append_string("#include \"rez3ext.h\"\n\n");
    out.append_string("static RezCavity *f_field;\n");
    for (sz i = 0; i < frames.len(); i++) {
        if (frames[i].scope == 0 && !frames[i].is_field) {
            out.appendf("static RezCavity *%s;\n", frames[i].cname);
        }
    }
    for (sz i = 0; i < cells.len(); i++) {
        if (cells[i].scope == 0) {
            out.appendf("static void *%s;\n", cells[i].cname);
        }
    }
    for (sz i = 0; i < meds.len(); i++) {
        if (meds[i].scope == 0) {
            out.appendf("static RezCellMed %s;\n", meds[i].cname);
        }
    }
    for (sz i = 0; i < procs.len(); i++) {
        out.appendf("static RezCavity %s;\n", frames[procs[i].frame].cname);
        int pscope = (int)i + 1;
        for (sz j = 0; j < frames.len(); j++) {
            if (frames[j].scope == pscope && !frames[j].is_procframe) {
                out.appendf("static RezCavity *%s;\n", frames[j].cname);
            }
        }
        for (sz j = 0; j < cells.len(); j++) {
            if (cells[j].scope == pscope) {
                out.appendf("static void *%s;\n", cells[j].cname);
            }
        }
        for (sz j = 0; j < meds.len(); j++) {
            if (meds[j].scope == pscope) {
                out.appendf("static RezCellMed %s;\n", meds[j].cname);
            }
        }
    }
    out.append_string("\n");
    for (sz i = 0; i < procs.len(); i++) {
        if (g_lib_mode) {
            out.appendf("void rza_%s(void);\n", procs[i].name);
        } else {
            out.appendf("static void %s(void);\n", procs[i].cname);
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
    return out.copy_str(mem);
}

// --- CLI ----------------------------------------------------------------------------
fn int main(String[] args) {
    reset_state();

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
            return lsp_main();   // LSP-цикл; возврат = код выхода сервера
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
            src = a;
        }
    }
    if (src.len == 0) {
        io::eprintfn("usage: rez3asm file.rza [--emit-c | --emit-lib] [-o file.c] | rez3asm --lsp");
        io::eprintfn("  -o без --emit-c/--emit-lib тоже включает эмиссию C");
        return 2;
    }
    srcname = src;
    char[]? data = file::load(mem, src);
    if (catch data) {
        io::eprintfn("rez3asm: cannot open %s", src);
        return 2;
    }
    run((String)data);
    if (violations > 0) return 1;
    if (emit_c || outpath.len > 0) {
        String code = emit();
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
