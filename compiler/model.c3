// REZ3-ASM (.rza) -> C23. C3 0.8.5_1; shared runtime is in refs/.
// CLI: rez3asm file.rza [--emit-c | --emit-lib] [-o file.c]
//      rez3asm --lsp
// Ownership invariants use one pass; labels are resolved in a second pass.
// Loading or storing through a dead mediator is a runtime FAULT.
module rez3asm;

import std::io;
import std::io::file;
import std::core::dstring;
import std::core::mem::allocators;
import std::collections::list;
import std::hash::sha256;

const int NODE_MAX = 16384;
const int CELL_MED_MAX = 64;
const int CASC_MED_MAX = 64;
const int SOURCE_BYTES_MAX = 1048576;
const int OUTPUT_BYTES_MAX = 67108864;
const int CELL_SIZE_BYTES_MAX = 2147483632;
const int WORK_BYTES = 134217728;
const sz OFFSET_STRING_BYTES = 96;

char[WORK_BYTES] work_storage;
ArenaAllocator work_arena;
Allocator workmem;
AllocationGuard list_guard;
Allocator list_mem;
ScratchMemory load_offset_scratch;
ScratchMemory store_offset_scratch;

fn void init_workmem() {
    work_arena.init(work_storage[..]);
    workmem = &work_arena;
    load_offset_scratch.init(workmem, OFFSET_STRING_BYTES);
    store_offset_scratch.init(workmem, OFFSET_STRING_BYTES);
    list_guard.init(mem);
    list_mem = &list_guard;
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

enum ScalarType : char { U8, I64 }

struct LayoutField {
    String name;
    ScalarType scalar_type;
    int offset_bytes;
}

struct Layout {
    String name;
    int first_field;
    int field_count;
    int size_bytes;
    int alignment_bytes;
}

struct Cell {
    String name;
    int    owner;         // текущий владелец после raise
    int    home;          // рамка, которой принадлежит физическая память
    int    size;
    String cname;
    int    scope;
    bool   async_out;
    int    layout;        // -1 = raw bytes
    int    element_count; // 0 = raw bytes
    int[CELL_MED_MAX] med_idxs;
    int    med_count;
}

struct Med {
    String name;
    int    cell;          // индекс Cell
    int    owner;         // владелец на момент объявления медиатора
    uint   gen;
    uint   home_gen;
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
    LABEL, JMP, BRZ, BRNZ, CALL, AWAIT, RET
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
    long   immediate;
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
List{Layout}  layouts;
List{LayoutField} layout_fields;
List{Cell}    cells;
List{Med}     meds;
List{Proc}    procs;
List{Cascade} cascades;
List{Block}   blocks;
List{LabelDef} labels;
List{Instr}   instrs;
NameMap frame_map;
NameMap layout_map;
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
char[32] source_hash;

bool g_state_inited = false;
