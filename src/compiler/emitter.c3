// REZ3-ASM (.rza) -> C23. C3 0.8.5_1; shared runtime is in include/rza/.
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
const long ARENA_FRAME_MAX = 16777216;
const long ARENA_TOTAL_MAX = 67108864;
bool emit_crc_direct = false;
bool[NODE_MAX] hoist_med;
bool[NODE_MAX] hoist_ready;
struct Output {
    DString text;
    sz max_bytes;
    bool overflow;
}

struct ProcEmitInfo {
    int first_instr;
    int last_instr;
    bool seen;
    bool has_crc32c;
    bool frame_free;
}

ProcEmitInfo[NODE_MAX] proc_emit_info;
int async_cascade_total = -1;

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

fn void prepare_emit_info() {
    assert(procs.len() <= NODE_MAX);
    for (sz i = 0; i < procs.len(); i++) {
        proc_emit_info[i] = { .first_instr = -1, .last_instr = -1, .frame_free = true };
    }
    int open_proc = -1;
    for (sz i = 0; i < instrs.len(); i++) {
        Instr* ins = &instrs[i];
        int pi = ins.func - 1;
        if (pi != open_proc) {
            if (open_proc >= 0) proc_emit_info[open_proc].last_instr = (int)i - 1;
            if (pi >= 0) {
                assert(!proc_emit_info[pi].seen);
                proc_emit_info[pi].first_instr = (int)i;
                proc_emit_info[pi].seen = true;
            }
            open_proc = pi;
        }
        if (pi < 0) continue;
        if (ins.op == Op.ALU3 && ins.s2 == "crc32c") {
            proc_emit_info[pi].has_crc32c = true;
        }
        switch (ins.op) {
            case Op.CAV: case Op.RES: case Op.MED: case Op.RAISE: case Op.DECAY:
            case Op.PROBE: case Op.CASC: case Op.AWAIT: case Op.CALL:
                proc_emit_info[pi].frame_free = false;
            default:
                break;
        }
    }
    if (open_proc >= 0) proc_emit_info[open_proc].last_instr = (int)instrs.len() - 1;
    for (sz i = 0; i < procs.len(); i++) {
        assert(proc_emit_info[i].seen);
        assert(proc_emit_info[i].first_instr >= 0);
        assert(proc_emit_info[i].last_instr >= proc_emit_info[i].first_instr);
    }
    async_cascade_total = 0;
    for (sz i = 0; i < cascades.len(); i++) {
        if (cascades[i].is_async) async_cascade_total++;
    }
}

fn void func_instr_bounds(int func, int* first, int* end) {
    if (func == 0) {
        *first = 0;
        *end = (int)instrs.len();
        return;
    }
    ProcEmitInfo* info = &proc_emit_info[func - 1];
    assert(info.seen);
    *first = info.first_instr;
    *end = info.last_instr + 1;
}

// битмаски чтения/записи регистров функции
fn void scan_regs(int func, uint* rd, uint* wr) {
    *rd = 0; *wr = 0;
    int first, end;
    func_instr_bounds(func, &first, &end);
    for (int i = first; i < end; i++) {
        Instr* ins = &instrs[i];
        if (func == 0 && ins.func != 0) continue;
        switch (ins.op) {
            case Op.LOAD:
                *wr |= 1u << ins.a;
                if (ins.c >= 0) *rd |= 1u << ins.c;
            case Op.STORE:
                *rd |= 1u << ins.a;
                if (ins.c >= 0) *rd |= 1u << ins.c;
            case Op.VIEW:
                if (!meds[ins.x].view_offset.is_immediate) {
                    *rd |= 1u << meds[ins.x].view_offset.reg;
                }
                if (!meds[ins.x].view_length.is_immediate) {
                    *rd |= 1u << meds[ins.x].view_length.reg;
                }
            case Op.MOV:
                if (!ins.flag && ins.a == ins.b) break;
                *wr |= 1u << ins.a;
                if (!ins.flag) *rd |= 1u << ins.b;
            case Op.ALU3:
                *wr |= 1u << ins.a;
                if (ins.s2 == "<" && !ins.flag && ins.b == ins.c) break;
                *rd |= 1u << ins.b;
                if (!ins.flag) *rd |= 1u << ins.c;
            case Op.ALU1:
                *rd |= 1u << ins.a;
                *wr |= 1u << ins.a;
            case Op.PRINT: *rd |= 1u << ins.a;
            case Op.AWAIT: *wr |= 1u << ins.a;
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

// Полные глобальные медиаторы инициализируются при создании res или OUT.
fn void emit_hoisted_meds(Output* out, int ind, int cell) {
    for (int i = 0; i < cells[cell].med_count; i++) {
        int mi = cells[cell].med_idxs[i];
        if (meds[mi].scope != 0 || meds[mi].view_source >= 0) continue;
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

fn Cell* validated_access_cell(Instr* ins) {
    assert(ins.x >= 0 && ins.x < (int)meds.len());
    Cell* cell = &cells[meds[ins.x].cell];
    if (ins.y < 0) {
        assert(cell.layout == -1);
        assert(ins.y == -1);
        return cell;
    }
    assert(cell.layout >= 0 && cell.layout < (int)layouts.len());
    Layout layout = layouts[cell.layout];
    assert(ins.y >= layout.first_field);
    assert(ins.y < layout.first_field + layout.field_count);
    assert(ins.y < (int)layout_fields.len());
    bool byte_field = layout_fields[ins.y].scalar_type == ScalarType.U8;
    assert(ins.flag == byte_field);
    return cell;
}

fn void append_access_offset(DString* out, Instr* ins) {
    Cell* cell = validated_access_cell(ins);
    if (cell.layout < 0) {
        if (ins.c >= 0) { out.appendf("r%d", ins.c); }
        else { out.appendf("%d", ins.b); }
        return;
    }
    int stride = layouts[cell.layout].size_bytes;
    int field_offset = layout_fields[ins.y].offset_bytes;
    assert(stride > 0 && cell.element_count > 0);
    if (ins.c >= 0) {
        out.appendf("(uint64_t)r%d * %d + %d", ins.c, stride, field_offset);
    } else {
        assert(ins.b >= 0 && ins.b < cell.element_count);
        long offset = (long)ins.b * stride + field_offset;
        int width = ins.flag ? 1 : 8;
        assert(offset >= 0 && offset + width <= cell.size);
        out.appendf("%d", offset);
    }
    assert(out.len() < OFFSET_STRING_BYTES);
}

fn String fault_code(String reason) {
    switch (reason) {
        case "dead mediator": return "RZA_FAULT_DEAD_MEDIATOR";
        case "out of bounds": return "RZA_FAULT_OUT_OF_BOUNDS";
        case "arithmetic overflow": return "RZA_FAULT_ARITHMETIC_OVERFLOW";
        case "division": return "RZA_FAULT_DIVISION";
        case "shift": return "RZA_FAULT_SHIFT";
        case "invalid view": return "RZA_FAULT_VIEW";
        case "async queue full": return "RZA_FAULT_ASYNC_QUEUE";
        default: unreachable();
    }
}

fn void emit_coded_fault(Output* out, int ind, String code, int line,
        String reason, String name) {
    pad(out, ind);
    String subject = name.len == 0 ? "nullptr" : cat({ "\"", name, "\"" });
    out.appendf("rez3asm_fault(%s, %d, \"%s\", %s);\n", code, line, reason, subject);
    pad(out, ind);
    out.append_string("goto rza_fault;\n");
}

fn void emit_fault(Output* out, int ind, int line, String reason, String name) {
    emit_coded_fault(out, ind, fault_code(reason), line, reason, name);
}

fn void emit_diagnostic_support(Output* out) {
    out.append_string("static RzaResult g_result;\n");
    if (g_lib_mode) {
        out.append_string("static RzaDiagnosticHandler g_diag;\n");
        out.append_string("static void *g_diag_context;\n");
    }
    out.append_string("static void rez3asm_diagnostic(uint32_t fault, int line,\n");
    out.append_string("    const char *operation, const char *subject) {\n");
    out.append_string("    RzaDiagnostic diagnostic = {\n");
    out.append_string("        fault, (uint32_t)line, operation, subject\n");
    out.append_string("    };\n");
    if (g_lib_mode) {
        out.append_string("    if (g_diag != nullptr) g_diag(diagnostic, g_diag_context);\n");
    } else {
        out.append_string("    (void)diagnostic;\n");
        out.append_string("    if (fault == RZA_ABORT) {\n");
        out.append_string("        fprintf(\n");
        out.append_string("            stderr, \"ABORT line %d: cascade %s: \"\n");
        out.append_string("            \"dead mediator %s\\n\",\n");
        out.append_string("            line, operation, subject);\n");
        out.append_string("    } else if (fault == RZA_FAULT_ASYNC_PENDING) {\n");
        out.append_string("        fprintf(stderr, \"FAULT line %d: async task %s \"\n");
        out.append_string("            \"already pending\\n\", line, subject);\n");
        out.append_string("    } else if (fault == RZA_FAULT_ARENA) {\n");
        out.append_string("        fprintf(stderr, \"FAULT line %d: arena overflow \"\n");
        out.append_string("            \"(%s %s)\\n\", line, operation, subject);\n");
        out.append_string("    } else if (subject != nullptr) {\n");
        out.append_string("        fprintf(stderr, \"FAULT line %d: %s %s\\n\",\n");
        out.append_string("            line, operation, subject);\n");
        out.append_string("    } else {\n");
        out.append_string("        fprintf(stderr, \"FAULT line %d: %s\\n\", line, operation);\n");
        out.append_string("    }\n");
    }
    out.append_string("}\n\n");
    out.append_string("static void rez3asm_fault(uint32_t fault, int line,\n");
    out.append_string("    const char *operation, const char *subject) {\n");
    out.append_string("    if (g_result.code != RZA_OK) return;\n");
    out.append_string("    g_result = (RzaResult){ fault, (uint32_t)line };\n");
    out.append_string("    rez3asm_diagnostic(fault, line, operation, subject);\n");
    out.append_string("}\n\n");
    out.append_string("[[maybe_unused]] static void rez3asm_abort(\n");
    out.append_string("    int line, const char *cascade, const char *name) {\n");
    out.append_string("    rez3asm_diagnostic(RZA_ABORT, line, cascade, name);\n");
    out.append_string("}\n\n");
}

fn void emit_host_support(Output* out) {
    if (!g_lib_mode) return;
    out.append_string("static bool g_active;\nstatic bool g_boot_started;\n");
    out.append_string("static RzaResult rez3asm_entry_result(void) {\n");
    out.append_string("    return (RzaResult){ RZA_FAULT_ENTRY_STATE, 0 };\n}\n\n");
    out.append_string("static bool rez3asm_host_enter(void) {\n");
    out.append_string("    if (g_active) return false;\n");
    out.append_string("    g_active = true;\n");
    out.append_string("    g_result = (RzaResult){0};\n");
    out.append_string("    return true;\n}\n\n");
    out.append_string("static RzaResult rez3asm_host_leave(void) {\n");
    out.append_string("    g_active = false;\n    return g_result;\n}\n\n");
}

fn void emit_fault_support(Output* out) {
    emit_diagnostic_support(out);
    emit_host_support(out);
}

fn void emit_dynamic_bounds_guard(Output* out, int ind, Instr* ins) {
    Cell* cell = validated_access_cell(ins);
    int width = ins.flag ? 1 : 8;
    pad(out, ind);
    if (cell.layout >= 0 && ins.c >= 0) {
        int stride = layouts[cell.layout].size_bytes;
        out.appendf("if (r%d < 0 || (uint64_t)r%d >= %s.size / %d) {\n",
                    ins.c, ins.c, meds[ins.x].cname, stride);
    } else {
        long offset = ins.b;
        if (cell.layout >= 0) {
            int stride = layouts[cell.layout].size_bytes;
            offset = offset * stride + layout_fields[ins.y].offset_bytes;
        }
        if (ins.c >= 0) {
            out.appendf("if (!rez_cell_bounds(%s, (uint64_t)r%d, %d)) {\n",
                        meds[ins.x].cname, ins.c, width);
        } else {
            out.appendf("if (!rez_cell_bounds(%s, %d, %d)) {\n",
                        meds[ins.x].cname, offset, width);
        }
    }
    emit_fault(out, ind + 1, ins.line, "out of bounds", meds[ins.x].name);
    pad(out, ind);
    out.append_string("}\n");
}

fn void emit_bounds_guard(Output* out, int ind, Instr* ins) {
    int extent = meds[ins.x].extent;
    if (extent < 0) {
        emit_dynamic_bounds_guard(out, ind, ins);
        return;
    }
    if (ins.c < 0) return;
    Cell* cell = validated_access_cell(ins);
    pad(out, ind);
    if (cell.layout >= 0) {
        out.appendf("if (r%d < 0 || (uint64_t)r%d >= %d) {\n", ins.c, ins.c, extent);
    } else {
        int width = ins.flag ? 1 : 8;
        assert(width > 0);
        if (extent < width) {
            out.append_string("if (1) {\n");
        } else {
            out.appendf("if ((uint64_t)r%d > %d) {\n", ins.c, extent - width);
        }
    }
    emit_fault(out, ind + 1, ins.line, "out of bounds", meds[ins.x].name);
    pad(out, ind);
    out.append_string("}\n");
}

fn String deref_helper(Instr* ins) {
    if (ins.func > 0 && proc_frame_free(ins.func - 1)) return "rez_deref_cell_inline";
    return "rez_deref_cell";
}

fn void emit_hoist_guard(Output* out, int ind, Instr* ins) {
    String name = meds[ins.x].name;
    pad(out, ind);
    out.appendf("void *p_%s = %s(%s);\n", name, deref_helper(ins), meds[ins.x].cname);
    pad(out, ind);
    out.appendf("if (!p_%s) {\n", name);
    emit_fault(out, ind + 1, ins.line, "dead mediator", name);
    pad(out, ind);
    out.append_string("}\n");
}

fn void emit_load(Output* out, int ind, Instr* ins, bool in_casc) {
    DString* oex = load_offset_scratch.acquire(OFFSET_STRING_BYTES);
    assert(oex != null);
    defer assert(load_offset_scratch.release(oex));
    append_access_offset(oex, ins);
    bool hoisted = !in_casc && hoist_med[ins.x];
    String ptr = in_casc || hoisted ? cat({"p_", meds[ins.x].name}) : "p";
    if (hoisted && !hoist_ready[ins.x]) {
        emit_hoist_guard(out, ind, ins);
        hoist_ready[ins.x] = true;
    }
    if (!in_casc && !hoisted) {
        pad(out, ind);
        out.appendf("{ void *p = %s(%s);\n", deref_helper(ins), meds[ins.x].cname);
        pad(out, ind);
        out.append_string("if (!p) {\n");
        emit_fault(out, ind + 1, ins.line, "dead mediator", meds[ins.x].name);
        pad(out, ind);
        out.append_string("}\n");
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
    out.append_string(in_casc || hoisted ? "\n" : " }\n");
}

fn void emit_store(Output* out, int ind, Instr* ins, bool in_casc) {
    DString* sex = store_offset_scratch.acquire(OFFSET_STRING_BYTES);
    assert(sex != null);
    defer assert(store_offset_scratch.release(sex));
    append_access_offset(sex, ins);
    bool hoisted = !in_casc && hoist_med[ins.x];
    String ptr = in_casc || hoisted ? cat({"p_", meds[ins.x].name}) : "p";
    if (hoisted && !hoist_ready[ins.x]) {
        emit_hoist_guard(out, ind, ins);
        hoist_ready[ins.x] = true;
    }
    if (!in_casc && !hoisted) {
        pad(out, ind);
        out.appendf("{ void *p = %s(%s);\n", deref_helper(ins), meds[ins.x].cname);
        pad(out, ind);
        out.append_string("if (!p) {\n");
        emit_fault(out, ind + 1, ins.line, "dead mediator", meds[ins.x].name);
        pad(out, ind);
        out.append_string("}\n");
        ind++;
    }
    emit_bounds_guard(out, ind, ins);
    pad(out, ind);
    if (ins.flag) {
        out.appendf("*(unsigned char*)((char*)%s + %s) = (unsigned char)r%d;",
                    ptr, sex.str_view(), ins.a);
    } else {
        out.appendf("memcpy((char*)%s + %s, &r%d, 8);",
                    ptr, sex.str_view(), ins.a);
    }
    out.append_string(in_casc || hoisted ? "\n" : " }\n");
}

fn void emit_checked_arith(Output* out, int ind, Instr* ins, String helper, String rhs) {
    pad(out, ind);
    out.appendf("if (%s(r%d, %s, &r%d)) {\n", helper, ins.b, rhs, ins.a);
    emit_fault(out, ind + 1, ins.line, "arithmetic overflow", "");
    pad(out, ind);
    out.append_string("}\n");
}

fn void emit_alu3(Output* out, int ind, Instr* ins) {
    DString rhs = dstring::new(workmem);
    defer rhs.free();
    if (ins.flag && ins.immediate == -9223372036854775807 - 1) {
        rhs.append("INT64_MIN");
    } else if (ins.flag) { rhs.appendf("%d", ins.immediate); }
    else { rhs.appendf("r%d", ins.c); }
    if (ins.s2 == "<") {
        pad(out, ind);
        if (!ins.flag && ins.b == ins.c) {
            out.appendf("r%d = 0;\n", ins.a);
        } else {
            out.appendf("r%d = r%d < %s;\n", ins.a, ins.b, rhs.str_view());
        }
        return;
    }
    bool division = ins.s2 == "/" || ins.s2 == "%";
    bool shift = ins.s2 == "<<" || ins.s2 == ">>" || ins.s2 == ">>>";
    if (division) {
        pad(out, ind);
        out.appendf("if (%s == 0 || (r%d == INT64_MIN && %s == -1)) {\n",
                    rhs.str_view(), ins.b, rhs.str_view());
        emit_fault(out, ind + 1, ins.line, "division", "");
        pad(out, ind);
        out.append_string("}\n");
    }
    if (shift) {
        pad(out, ind);
        out.appendf("if (%s < 0 || %s >= 64) {\n",
                    rhs.str_view(), rhs.str_view());
        emit_fault(out, ind + 1, ins.line, "shift", "");
        pad(out, ind);
        out.append_string("}\n");
    }
    String checked = "";
    if (ins.s2 == "c+") checked = "rez_i64_cadd";
    if (ins.s2 == "c-") checked = "rez_i64_csub";
    if (ins.s2 == "c*") checked = "rez_i64_cmul";
    if (checked.len > 0) {
        emit_checked_arith(out, ind, ins, checked, rhs.str_view());
        return;
    }
    String helper = "";
    if (ins.s2 == "+") helper = "rez_i64_add";
    if (ins.s2 == "-") helper = "rez_i64_sub";
    if (ins.s2 == "*") helper = "rez_i64_mul";
    if (ins.s2 == "/") helper = "rez_i64_div";
    if (ins.s2 == "%") helper = "rez_i64_mod";
    if (ins.s2 == "<<") helper = "rez_i64_shl";
    if (ins.s2 == ">>") helper = "rez_i64_shr";
    if (ins.s2 == ">>>") helper = "rez_i64_ushr";
    if (ins.s2 == "crc32c") {
        helper = emit_crc_direct ? "rez_crc32c_u64_x86" : "rez_crc32c_u64";
    }
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

fn String view_operand_expr(ViewOperand operand) {
	if (operand.immediate == -9223372036854775807 - 1 && operand.is_immediate) {
		return "(uint64_t)INT64_MIN";
	}
	DString out = dstring::new(workmem);
	defer out.free();
	if (operand.is_immediate) {
		out.appendf("(uint64_t)%d", operand.immediate);
	} else {
		out.appendf("(uint64_t)r%d", operand.reg);
	}
	return out.copy_str(workmem);
}

fn String view_snapshot_name(int mi, String kind) {
	return cat({ "v", kind, "_", meds[mi].cname });
}

fn void emit_view_build(Output* out, int ind, int mi) {
	int source = meds[mi].view_source;
	assert(source >= 0 && source < (int)meds.len());
	int ci = meds[mi].cell;
	int stride = cells[ci].layout >= 0 ? layouts[cells[ci].layout].size_bytes : 1;
	pad(out, ind);
	out.append_string("if (!rez_view_cell(\n");
	pad(out, ind + 1);
	out.appendf("%s,\n", meds[source].cname);
	pad(out, ind + 1);
	out.appendf("%s,\n", view_snapshot_name(mi, "off"));
	pad(out, ind + 1);
	out.appendf("%s,\n", view_snapshot_name(mi, "len"));
	pad(out, ind + 1);
	out.appendf("%d, &%s\n", stride, meds[mi].cname);
	pad(out, ind);
	out.append_string(")) {\n");
	emit_fault(out, ind + 1, meds[mi].line, "invalid view", meds[mi].name);
	pad(out, ind);
	out.append_string("}\n");
}

fn void emit_view(Output* out, int ind, int mi) {
	pad(out, ind);
	out.appendf("%s = %s;\n", view_snapshot_name(mi, "off"),
	            view_operand_expr(meds[mi].view_offset));
	pad(out, ind);
	out.appendf("%s = %s;\n", view_snapshot_name(mi, "len"),
	            view_operand_expr(meds[mi].view_length));
	emit_view_build(out, ind, mi);
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
            emit_coded_fault(out, ind + 1, "RZA_FAULT_FRAME", ins.line,
                             "frame allocation", frames[ins.x].name);
            pad(out, ind);
            out.append_string("}\n");
        case Op.RES:
            pad(out, ind);
            out.appendf("%s = rez_cell_z(%s, %d);\n",
                        cells[ins.x].cname, fexpr(ins.y), ins.a);
            pad(out, ind);
            out.appendf("if (!%s) {\n", cells[ins.x].cname);
            emit_coded_fault(out, ind + 1, "RZA_FAULT_ARENA", ins.line,
                             "cell", cells[ins.x].name);
            pad(out, ind);
            out.append_string("}\n");
            emit_hoisted_meds(out, ind, ins.x);
        case Op.MED:
            if (ins.func == 0) break;
            int ci = meds[ins.x].cell;
            if (cells[ci].async_out) break;
            pad(out, ind);
            out.appendf("%s = rez_issue_cell(\n", meds[ins.x].cname);
            pad(out, ind + 1);
            out.appendf("%s, %s, %s, %d\n",
                        fexpr(meds[ins.x].owner), fexpr(cells[ci].home),
                        cells[ci].cname, cells[ci].size);
            pad(out, ind);
            out.append_string(");\n");
        case Op.VIEW:
            emit_view(out, ind, ins.x);
        case Op.RAISE:
            pad(out, ind);
            out.appendf("/* raise %s -> %s (line %d): static-only; "
                        "no runtime code */\n",
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

fn void emit_clear_meds(Output* out, int ind, int cell) {
    for (int i = 0; i < cells[cell].med_count; i++) {
        int mi = cells[cell].med_idxs[i];
        pad(out, ind);
        out.appendf("%s = (RezCellMed){0};\n", meds[mi].cname);
    }
}

fn void emit_acasc_enqueue(Output* out, int ind, Instr* ins) {
    Cascade* ca = &cascades[ins.a];
    pad(out, ind);
    out.appendf("if (ac_pending_%d) {\n", ca.seq);
    emit_coded_fault(out, ind + 1, "RZA_FAULT_ASYNC_PENDING", ca.line,
                     "async task", ca.name);
    pad(out, ind);
    out.append_string("}\n");
    for (int i = 0; i < ca.med_count; i++) {
        int mi = ca.med_idxs[i];
        pad(out, ind);
        out.appendf("if (!rez_deref_cell(%s)) {\n", meds[mi].cname);
        pad(out, ind + 1);
        out.appendf("rez3asm_abort(%d, \"%s\", \"%s\");\n",
                    ca.line, ca.name, meds[mi].name);
        pad(out, ind + 1);
        out.appendf("goto casc_end_%d;\n", ca.seq);
        pad(out, ind);
        out.append_string("}\n");
    }
    pad(out, ind);
    out.appendf("if (ac_out_gen_%d == UINT32_MAX) {\n", ca.seq);
    emit_coded_fault(out, ind + 1, "RZA_FAULT_ASYNC_QUEUE", ca.line,
                     "async output generation exhausted", "");
    pad(out, ind);
    out.append_string("}\n");
    pad(out, ind);
    out.appendf("ac_out_gen_%d++;\n", ca.seq);
    pad(out, ind);
    out.appendf("if (%s == nullptr) {\n", cells[ca.out_cell].cname);
    pad(out, ind + 1);
    out.appendf("%s = rez_cell_z(%s, 8);\n",
                cells[ca.out_cell].cname, fexpr(ca.out_frame));
    pad(out, ind);
    out.append_string("}\n");
    pad(out, ind);
    out.appendf("if (!%s) {\n", cells[ca.out_cell].cname);
    emit_coded_fault(out, ind + 1, "RZA_FAULT_ARENA", ca.line,
                     "out", cells[ca.out_cell].name);
    pad(out, ind);
    out.append_string("}\n");
    pad(out, ind);
    out.appendf("memset(%s, 0, 8);\n", cells[ca.out_cell].cname);
    emit_clear_meds(out, ind, ca.out_cell);
    uint rd, wr;
    scan_regs(ins.func, &rd, &wr);
    pad(out, ind);
    out.appendf("memset(ac_state_%d.regs, 0, sizeof(ac_state_%d.regs));\n",
                ca.seq, ca.seq);
    for (int r = 0; r < 16; r++) {
        if ((rd | wr) & (1u << r)) {
            pad(out, ind);
            out.appendf("ac_state_%d.regs[%d] = r%d;\n", ca.seq, r, r);
        }
    }
    for (int i = 0; i < ca.med_count; i++) {
        int mi = ca.med_idxs[i];
        pad(out, ind);
        out.appendf("ac_state_%d.meds[%d] = %s;\n",
                    ca.seq, i, meds[mi].cname);
    }
    pad(out, ind);
    out.appendf("if (!rez_async_enqueue(&g_async, ac_run_%d, "
                "&ac_state_%d, &ac_pending_%d)) {\n", ca.seq, ca.seq, ca.seq);
    emit_fault(out, ind + 1, ca.line, "async queue full", "");
    pad(out, ind);
    out.append_string("}\n");
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
    if (ca.is_async) {
        emit_acasc_enqueue(out, ind, ins);
        return;
    }
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
        out.appendf("rez3asm_abort(%d, \"%s\", \"%s\");\n",
                    ca.line, ca.name, meds[mi].name);
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
    emit_coded_fault(out, ind + 1, "RZA_FAULT_ARENA", ca.line,
                     "out", cells[ca.out_cell].name);
    pad(out, ind);
    out.append_string("}\n");
    emit_hoisted_meds(out, ind, ca.out_cell);
}

fn void emit_mov(Output* out, int ind, Instr* ins) {
    if (!ins.flag && ins.a == ins.b) return;
    pad(out, ind);
    if (ins.flag) {
        if (ins.immediate == -9223372036854775807 - 1) {
            out.appendf("r%d = INT64_MIN;\n", ins.a);
        } else {
            out.appendf("r%d = %d;\n", ins.a, ins.immediate);
        }
    } else {
        out.appendf("r%d = r%d;\n", ins.a, ins.b);
    }
}

fn void emit_casc_instructions(Output* out, int ind, Cascade* ca) {
    for (sz i = 0; i < instrs.len(); i++) {
        Instr* ins = &instrs[i];
        if (ins.block != ca.block || ins.op == Op.ENDC) continue;
        switch (ins.op) {
            case Op.LABEL: emit_label(out, ind, ins);
            case Op.LOAD: emit_load(out, ind, ins, true);
            case Op.STORE: emit_store(out, ind, ins, true);
            case Op.MOV:
                emit_mov(out, ind, ins);
            case Op.ALU3: emit_alu3(out, ind, ins);
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
                out.appendf("if (r%d == 0) goto %s;\n", ins.a, label_cname(ins.block, ins.s1));
            case Op.BRNZ:
                pad(out, ind);
                out.appendf("if (r%d != 0) goto %s;\n", ins.a, label_cname(ins.block, ins.s1));
            default: break;
        }
    }
}

fn void emit_async_publish(Output* out, int ind, int cell, int seq) {
    for (int i = 0; i < cells[cell].med_count; i++) {
        int mi = cells[cell].med_idxs[i];
        if (meds[mi].view_source >= 0) continue;
        pad(out, ind);
        out.appendf("%s = rez_issue_cell_versioned(\n", meds[mi].cname);
        pad(out, ind + 1);
        out.appendf("%s, %s, %s, %d, &ac_out_gen_%d\n",
                    fexpr(meds[mi].owner), fexpr(cells[cell].home),
                    cells[cell].cname, cells[cell].size, seq);
        pad(out, ind);
        out.append_string(");\n");
    }
    for (int i = 0; i < cells[cell].med_count; i++) {
        int mi = cells[cell].med_idxs[i];
        if (meds[mi].view_source >= 0) emit_view_build(out, ind, mi);
    }
}

fn uint scan_casc_regs(Cascade* ca) {
    uint mask = 0;
    for (sz i = 0; i < instrs.len(); i++) {
        Instr* ins = &instrs[i];
        if (ins.block != ca.block) continue;
        switch (ins.op) {
            case Op.LOAD:
                mask |= 1u << ins.a;
                if (ins.c >= 0) mask |= 1u << ins.c;
            case Op.STORE:
                mask |= 1u << ins.a;
                if (ins.c >= 0) mask |= 1u << ins.c;
            case Op.MOV:
                if (!ins.flag && ins.a == ins.b) break;
                mask |= 1u << ins.a;
                if (!ins.flag) mask |= 1u << ins.b;
            case Op.ALU3:
                mask |= 1u << ins.a;
                if (ins.s2 == "<" && !ins.flag && ins.b == ins.c) break;
                mask |= 1u << ins.b;
                if (!ins.flag) mask |= 1u << ins.c;
            case Op.ALU1: case Op.PRINT: case Op.BRZ: case Op.BRNZ:
                mask |= 1u << ins.a;
            default: break;
        }
    }
    return mask;
}

fn void emit_async_callback(Output* out, int ci) {
    Cascade* ca = &cascades[ci];
    out.appendf("typedef struct { RezCellMed meds[%d]; int64_t regs[16]; } AcState_%d;\n",
                ca.med_count, ca.seq);
    out.appendf("static AcState_%d ac_state_%d;\n", ca.seq, ca.seq);
    out.appendf("static bool ac_pending_%d;\n", ca.seq);
    out.appendf("static uint32_t ac_out_gen_%d = 1;\n", ca.seq);
    out.appendf("static RzaResult ac_run_%d(void *context) {\n", ca.seq);
    out.append_string("    (void)context;\n");
    uint mask = scan_casc_regs(ca);
    for (int r = 0; r < 16; r++) {
        if (mask & (1u << r)) {
            out.appendf("    int64_t r%d = ac_state_%d.regs[%d];\n", r, ca.seq, r);
        }
    }
    for (int i = 0; i < ca.med_count; i++) {
        int mi = ca.med_idxs[i];
        out.appendf("    void *p_%s = rez_deref_cell(ac_state_%d.meds[%d]);\n",
                    meds[mi].name, ca.seq, i);
        out.appendf("    if (!p_%s) {\n", meds[mi].name);
        out.appendf("        rez3asm_abort(%d, \"%s\", \"%s\");\n",
                    ca.line, ca.name, meds[mi].name);
        out.appendf("        ac_pending_%d = false;\n", ca.seq);
        out.appendf("        return (RzaResult){ RZA_ABORT, %d };\n", ca.line);
        out.append_string("    }\n");
    }
    emit_casc_instructions(out, 1, ca);
    out.appendf("    ac_pending_%d = false;\n", ca.seq);
    emit_async_publish(out, 1, ca.out_cell, ca.seq);
    emit_drain_result_check(out);
    out.append_string("    return (RzaResult){0};\n");
    out.append_string("rza_fault:\n");
    out.appendf("    ac_pending_%d = false;\n", ca.seq);
    out.append_string("    return g_result;\n");
    out.append_string("}\n\n");
}

fn int async_cascade_count() {
    assert(async_cascade_total >= 0);
    return async_cascade_total;
}

fn bool program_has_async() {
    return async_cascade_count() > 0;
}

fn bool program_single_async() {
    return async_cascade_count() == 1;
}

fn String async_drain_expr() {
    if (program_single_async()) return "rez3asm_async_drain_single()";
    return "rez_async_drain(&g_async)";
}

fn void emit_drain_result_check(Output* out) {
    out.append_string("    if (g_result.code != RZA_OK) goto rza_fault;\n");
}

fn void emit_async_drain(Output* out) {
    if (!program_has_async()) return;
    out.appendf("    if (g_async.count != 0) (void)%s;\n", async_drain_expr());
    emit_drain_result_check(out);
}

fn void emit_proc_drain(Output* out, bool lifecycle) {
    if (!program_has_async() && (!g_lib_mode || !lifecycle)) return;
    out.appendf("    if (g_async.count != 0) (void)%s;\n", async_drain_expr());
    emit_drain_result_check(out);
}

fn void emit_async_callbacks(Output* out) {
    for (sz i = 0; i < cascades.len(); i++) {
        if (cascades[i].is_async) emit_async_callback(out, (int)i);
    }
}

fn void emit_async_cancel_support(Output* out) {
    out.append_string("[[maybe_unused]] static void rez3asm_cancel_async(void) {\n");
    out.append_string("    rez_async_cancel(&g_async);\n");
    for (sz i = 0; i < cascades.len(); i++) {
        if (cascades[i].is_async) {
            out.appendf("    ac_pending_%d = false;\n", cascades[i].seq);
        }
    }
    out.append_string("}\n\n");
}

fn void emit_async_single_drain(Output* out) {
    if (!program_single_async()) return;
    int seq = -1;
    for (sz i = 0; i < cascades.len(); i++) {
        if (cascades[i].is_async) seq = cascades[i].seq;
    }
    assert(seq > 0);
    out.append_string("[[maybe_unused]] static RzaAwaitResult\n");
    out.append_string("rez3asm_async_drain_single(void) {\n");
    out.append_string("    RzaAwaitResult drained = {0};\n");
    out.append_string("    assert(g_async.count <= REZ_ASYNC_MAX);\n");
    out.append_string("    while (g_async.count > 0) {\n");
    out.append_string("        RezAsyncTask task = g_async.tasks[g_async.head];\n");
    out.append_string("        RzaResult status;\n");
    out.appendf("        assert(task.run == ac_run_%d);\n", seq);
    out.append_string("        assert(task.context != nullptr);\n");
    out.append_string("        g_async.tasks[g_async.head] = (RezAsyncTask){0};\n");
    out.append_string("        g_async.head = (g_async.head + 1) % REZ_ASYNC_MAX;\n");
    out.append_string("        g_async.count--;\n");
    out.appendf("        status = ac_run_%d(task.context);\n", seq);
    out.append_string("        if (status.code == RZA_OK) drained.completed++;\n");
    out.append_string("        if (status.code != RZA_OK && status.code != RZA_ABORT) {\n");
    out.append_string("            drained.result = status;\n");
    out.append_string("            rez_async_cancel(&g_async);\n");
    out.append_string("            return drained;\n        }\n");
    out.append_string("    }\n");
    out.append_string("    g_async.head = 0;\n    return drained;\n}\n\n");
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

fn void emit_call(Output* out, int ind, Instr* ins) {
    pad(out, ind);
    out.appendf("if (!%s()) goto rza_fault;\n", procs[ins.x].cname);
}

fn void emit_await(Output* out, int ind, Instr* ins) {
    pad(out, ind);
    out.appendf("RzaAwaitResult awaited_%d = %s;\n", ins.line, async_drain_expr());
    pad(out, ind);
    out.appendf("r%d = (int64_t)awaited_%d.completed;\n", ins.a, ins.line);
    pad(out, ind);
    out.appendf("if (awaited_%d.result.code != RZA_OK) goto rza_fault;\n", ins.line);
}

fn bool is_async_block(int block) {
    if (block < 0 || block >= (int)blocks.len()) return false;
    if (blocks[block].kind != 2) return false;
    int ci = blocks[block].aux - 1;
    assert(ci >= 0);
    assert(ci < (int)cascades.len());
    return cascades[ci].is_async;
}

fn void hoist_reset() {
    for (sz i = 0; i < meds.len(); i++) {
        hoist_med[i] = false;
        hoist_ready[i] = false;
    }
}

fn bool hoist_allowed(Op op) {
    switch (op) {
        case Op.LOAD: case Op.STORE: case Op.MOV: case Op.ALU3: case Op.ALU1:
        case Op.PRINT: case Op.LABEL: case Op.JMP: case Op.BRZ: case Op.BRNZ:
        case Op.RET: case Op.RAISE: case Op.PROBE: case Op.VIEW:
            return true;
        default:
            return false;
    }
}

fn void proc_hoist_prepare(int pi) {
    hoist_reset();
    int first, end;
    func_instr_bounds(pi + 1, &first, &end);
    for (int i = first; i < end; i++) {
        if (!hoist_allowed(instrs[i].op)) return;
    }
    bool prefix = true;
    for (int i = first; i < end; i++) {
        Instr* ins = &instrs[i];
        if (ins.op == Op.JMP || ins.op == Op.BRZ || ins.op == Op.BRNZ) prefix = false;
        if (prefix && (ins.op == Op.LOAD || ins.op == Op.STORE)) hoist_med[ins.x] = true;
    }
}

fn void emit_body(Output* out, int func) {
    int ind = 1;
    assert(func >= 0 && func <= (int)procs.len());
    if (func == 0) {
        hoist_reset();
    } else {
        proc_hoist_prepare(func - 1);
    }
    int first, end;
    func_instr_bounds(func, &first, &end);
    for (int i = first; i < end; i++) {
        Instr* ins = &instrs[i];
        if ((func == 0 && ins.func != 0) || is_async_block(ins.block)) continue;
        assert(ins.line > 0);
        assert(ins.block < (int)blocks.len());
        bool in_casc = blocks[ins.block].kind == 2;
        switch (ins.op) {
            case Op.LABEL:
                emit_label(out, ind, ins);
            case Op.CAV: case Op.RES: case Op.MED: case Op.VIEW:
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
                emit_mov(out, ind, ins);
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
            case Op.CALL: emit_call(out, ind, ins);
            case Op.AWAIT: emit_await(out, ind, ins);
            case Op.RET:
                // Общий epilogue сначала делает drain, возврат происходит
                // только после него: top-level ret не обходит очередь.
                // ret процедуры закрывается emit_proc.
        }
    }
}

fn bool proc_has_crc32c(int pi) {
    assert(pi >= 0 && pi < (int)procs.len());
    assert(proc_emit_info[pi].seen);
    return proc_emit_info[pi].has_crc32c;
}

fn bool crc_name_used(String candidate) {
    for (sz i = 0; i < procs.len(); i++) {
        String existing = g_lib_mode ? cat({ "rza_", procs[i].name }) : procs[i].cname;
        if (existing == candidate) return true;
    }
    return false;
}

fn String crc_variant_name(String base, String kind) {
    int salt = 0;
    while (true) {
        assert(salt >= 0 && salt <= (int)procs.len());
        DString out = dstring::new(workmem);
        defer out.free();
        out.appendf("%s_crc%d_%s", base, salt, kind);
        String candidate = out.copy_str(workmem);
        if (!crc_name_used(candidate)) return candidate;
        salt++;
    }
}

fn bool proc_frame_free(int pi) {
    assert(pi >= 0 && pi < (int)procs.len());
    assert(proc_emit_info[pi].seen);
    return proc_emit_info[pi].frame_free && !proc_emit_info[pi].has_crc32c;
}

fn void emit_proc_entry(Output* out, Proc* p) {
    out.appendf("[[maybe_unused]] static bool %s(void) {\n", p.cname);
}

fn void emit_proc_frame_reset(Output* out, Proc* p) {
    out.appendf("    if (!rez_frame_reset(&%s, f_field, A_%s, %d)) {\n",
                frames[p.frame].cname, frames[p.frame].cname, frames[p.frame].cap);
    emit_coded_fault(out, 2, "RZA_FAULT_FRAME", p.line, "frame allocation", p.name);
    out.append_string("    }\n");
}

fn void emit_proc_frame_decay(Output* out, Proc* p) {
    emit_decay_subtree(out, 1, p.frame);
    out.appendf("    rez_decay(&%s);\n", frames[p.frame].cname);
}

fn void emit_cancel_on_fault(Output* out, int ind) {
    if (!program_has_async()) return;
    pad(out, ind);
    out.append_string("rez3asm_cancel_async();\n");
}

fn void emit_proc_body(Output* out, int pi, bool lifecycle) {
    Proc* p = &procs[pi];
    uint rd, wr;
    scan_regs(pi + 1, &rd, &wr);
    emit_regs_decl(out, 1, rd | wr);
    if (lifecycle) emit_proc_frame_reset(out, p);
    emit_body(out, pi + 1);
    emit_proc_drain(out, lifecycle);
    emit_writeonly_silence(out, 1, rd, wr);
    emit_drain_result_check(out);
    if (lifecycle) emit_proc_frame_decay(out, p);
    out.append_string("    return true;\n");
    out.append_string("rza_fault:\n");
    emit_cancel_on_fault(out, 1);
    if (lifecycle) emit_proc_frame_decay(out, p);
    out.append_string("    return false;\n}\n");
}

fn void emit_host_enter(Output* out) {
    out.append_string("    if (!rez3asm_host_enter()) return rez3asm_entry_result();\n");
}

fn void emit_proc_wrapper(Output* out, Proc* p) {
    out.appendf("RzaResult rza_%s(void) {\n", p.name);
    emit_host_enter(out);
    out.appendf("    (void)%s();\n", p.cname);
    out.append_string("    return rez3asm_host_leave();\n}\n\n");
}

fn void emit_proc_host(Output* out, int pi) {
    Proc* p = &procs[pi];
    out.appendf("RzaResult rza_%s(void) {\n", p.name);
    emit_host_enter(out);
    emit_proc_frame_reset(out, p);
    out.appendf("    (void)%s();\n", p.cname);
    if (!program_has_async()) {
        out.appendf("    if (g_async.count != 0) (void)%s;\n", async_drain_expr());
    }
    emit_drain_result_check(out);
    emit_proc_frame_decay(out, p);
    out.append_string("    return rez3asm_host_leave();\n");
    out.append_string("rza_fault:\n");
    emit_cancel_on_fault(out, 1);
    emit_proc_frame_decay(out, p);
    out.append_string("    return rez3asm_host_leave();\n}\n\n");
}

fn void emit_proc(Output* out, int pi) {
    Proc* p = &procs[pi];
    assert(pi >= 0 && pi < (int)procs.len());
    assert(p.frame >= 0 && p.frame < (int)frames.len());
    assert(p.block >= 0 && p.block < (int)blocks.len());
    assert(p.line > 0 && p.cname.len > 0);
    assert(frames[p.frame].is_procframe);
    assert(frames[p.frame].cap <= ARENA_FRAME_MAX);
    if (proc_frame_free(pi)) {
        emit_proc_entry(out, p);
        emit_proc_body(out, pi, false);
        if (g_lib_mode) emit_proc_host(out, pi);
        return;
    }
    if (!proc_has_crc32c(pi)) {
        emit_proc_entry(out, p);
        emit_proc_body(out, pi, true);
        if (g_lib_mode) emit_proc_wrapper(out, p);
        return;
    }
    String base = g_lib_mode ? cat({ "rza_", p.name }) : p.cname;
    String portable = crc_variant_name(base, "portable");
    String hardware = crc_variant_name(base, "sse42");
    out.appendf("static bool %s(void) {\n", portable);
    emit_crc_direct = false;
    emit_proc_body(out, pi, true);
    out.append_string("#if REZ_CRC32C_X86\n");
    out.appendf("__attribute__((target(\"sse4.2\")))\nstatic bool %s(void) {\n",
                hardware);
    emit_crc_direct = true;
    emit_proc_body(out, pi, true);
    emit_crc_direct = false;
    out.append_string("#endif\n");
    emit_proc_entry(out, p);
    out.append_string("#if REZ_CRC32C_X86\n");
    out.appendf("    if (rez_crc32c_hardware()) return %s();\n#endif\n", hardware);
    out.appendf("    return %s();\n}\n\n", portable);
    if (g_lib_mode) emit_proc_wrapper(out, p);
}

fn void emit_top_core(Output* out, String name) {
    out.appendf("static bool %s(void) {\n", name);
    uint rd, wr;
    scan_regs(0, &rd, &wr);
    assert(frames[0].is_field);
    assert(frames[0].cap >= 64 && frames[0].cap <= ARENA_FRAME_MAX);
    assert(rd <= 0xFFFF && wr <= 0xFFFF);
    emit_regs_decl(out, 1, rd | wr);
    out.appendf("    if (!rez_frame_reset(f_field, nullptr, A_field, %d)) {\n",
                frames[0].cap);
    emit_coded_fault(out, 2, "RZA_FAULT_FRAME", 0, "frame allocation", "field");
    out.append_string("    }\n");
    emit_body(out, 0);
    if (g_lib_mode) {
        out.appendf("    if (g_async.count != 0) (void)%s;\n", async_drain_expr());
    } else {
        emit_async_drain(out);
    }
    emit_writeonly_silence(out, 1, rd, wr);
    emit_drain_result_check(out);
    out.append_string("    return true;\n");
    out.append_string("rza_fault:\n");
    emit_cancel_on_fault(out, 1);
    out.append_string("    return false;\n}\n\n");
}

fn void emit_main(Output* out) {
    emit_top_core(out, "rez3asm_main");
    out.append_string("int main(void) {\n");
    out.append_string("    (void)rez3asm_main();\n");
    out.append_string("    return g_result.code == RZA_OK ? 0 : 1;\n}\n");
}

fn void emit_boot(Output* out) {
    emit_top_core(out, "rez3asm_boot");
    out.append_string("RzaResult rza_boot(void) {\n");
    out.append_string("    if (g_active || g_boot_started) return rez3asm_entry_result();\n");
    out.append_string("    g_boot_started = true;\n");
    emit_host_enter(out);
    out.append_string("    (void)rez3asm_boot();\n");
    out.append_string("    return rez3asm_host_leave();\n}\n");
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
        if (!cells[ci].async_out && meds[i].view_source < 0) {
            out.appendf("    if (!%s.cell) {\n", meds[i].cname);
            out.appendf("        %s = rez_issue_cell(\n", meds[i].cname);
            out.appendf("            %s, %s, %s, %d\n",
                        fexpr(cells[ci].owner), fexpr(cells[ci].home),
                        cells[ci].cname, cells[ci].size);
            out.appendf("        );\n");
            out.append_string("    }\n");
        }
        out.appendf("    return %s;\n", meds[i].cname);
        out.append_string("}\n");
    }
    out.append_string("uint32_t rza_rez3ext_abi(void) { return REZ3EXT_ABI; }\n");
    out.append_string("void rza_set_diagnostic_handler(\n");
    out.append_string("    RzaDiagnosticHandler handler, void *context) {\n");
    out.append_string("    g_diag = handler;\n    g_diag_context = context;\n}\n");
    out.append_string("RzaAwaitResult rza_await(void) {\n");
    out.append_string("    if (!rez3asm_host_enter()) {\n");
    out.append_string("        return (RzaAwaitResult){\n");
    out.append_string("            .result = { RZA_FAULT_ENTRY_STATE, 0 }\n");
    out.append_string("        };\n");
    out.append_string("    }\n");
    out.appendf("    RzaAwaitResult drained = %s;\n", async_drain_expr());
    out.append_string("    if (drained.result.code != RZA_OK) rez3asm_cancel_async();\n");
    out.append_string("    drained.result = rez3asm_host_leave();\n");
    out.append_string("    return drained;\n}\n");
    out.append_string("void *rza_arena_alloc(RezCavity *cavity, uint64_t size) "
                      "{ return rez_cell_z(cavity, size); }\n");
    out.append_string("void *rza_deref_cell(RezCellMed mediator) "
                      "{ return rez_deref_cell(mediator); }\n");
}

fn void emit_proc_frame_storage(Output* out, int pi) {
    if (proc_frame_free(pi)) out.append_string("[[maybe_unused]] ");
    out.appendf("static RezCavity %s;\n", frames[procs[pi].frame].cname);
    if (proc_frame_free(pi)) out.append_string("[[maybe_unused]] ");
    out.appendf("_Alignas(REZ_ALIGNMENT) static char A_%s[%d];\n",
                frames[procs[pi].frame].cname, frames[procs[pi].frame].cap);
}

fn void emit_view_snapshot_storage(Output* out, int mi) {
    out.appendf("[[maybe_unused]] static uint64_t %s;\n",
                view_snapshot_name(mi, "off"));
    out.appendf("[[maybe_unused]] static uint64_t %s;\n",
                view_snapshot_name(mi, "len"));
}

fn void emit_static_storage(Output* out) {
    out.append_string("static RezCavity S_field;\n");
    out.append_string("static RezCavity *f_field = &S_field;\n");
    out.appendf("_Alignas(REZ_ALIGNMENT) static char A_field[%d];\n", frames[0].cap);
    for (sz i = 0; i < frames.len(); i++) {
        assert(frames[i].cname.len > 0);
        assert(frames[i].cap >= 64);
        assert(frames[i].cap <= ARENA_FRAME_MAX);
        assert(frames[i].scope >= 0);
        if (frames[i].scope == 0 && !frames[i].is_field) {
            out.appendf("static RezCavity S_%s;\n", frames[i].cname);
            out.appendf("static RezCavity *%s = &S_%s;\n",
                        frames[i].cname, frames[i].cname);
            out.appendf("_Alignas(REZ_ALIGNMENT) static char A_%s[%d];\n",
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
            out.appendf("[[maybe_unused]] static RezCellMed %s;\n", meds[i].cname);
        }
        if (meds[i].view_source >= 0) emit_view_snapshot_storage(out, (int)i);
    }
    for (sz i = 0; i < procs.len(); i++) {
        assert(procs[i].frame >= 0);
        assert(procs[i].frame < (int)frames.len());
        assert(procs[i].block >= 0);
        assert(procs[i].block < (int)blocks.len());
        assert(procs[i].cname.len > 0);
        emit_proc_frame_storage(out, (int)i);
        int pscope = (int)i + 1;
        for (sz j = 0; j < frames.len(); j++) {
            if (frames[j].scope == pscope && !frames[j].is_procframe) {
                out.appendf("static RezCavity S_%s;\n", frames[j].cname);
                out.appendf("static RezCavity *%s = &S_%s;\n",
                            frames[j].cname, frames[j].cname);
                out.appendf("_Alignas(REZ_ALIGNMENT) static char A_%s[%d];\n",
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
                out.appendf("[[maybe_unused]] static RezCellMed %s;\n", meds[j].cname);
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
    prepare_emit_info();
    out.append_string("/* Source-SHA256: ");
    foreach (byte : source_hash) out.appendf("%02x", (uint)byte);
    out.append_string(" */\n");
    out.append_string("/* Generated by rez3asm (C3) — REZ3-ASM -> C23 */\n");
    out.append_string("#include <stdio.h>\n");
    out.append_string("#include <stdint.h>\n");
    out.append_string("#include <stdlib.h>\n");
    out.append_string("#include \"rez3ext.h\"\n\n");
    emit_fault_support(&out);
    emit_static_storage(&out);
    out.append_string("RezAsyncQueue g_async;\n\n");
    emit_async_callbacks(&out);
    emit_async_cancel_support(&out);
    emit_async_single_drain(&out);
    for (sz i = 0; i < procs.len(); i++) {
        if (g_lib_mode && proc_frame_free((int)i)) {
            out.appendf("static bool %s(void);\n", procs[i].cname);
        }
        if (g_lib_mode) {
            out.appendf("RzaResult rza_%s(void);\n", procs[i].name);
        } else {
            out.appendf("[[maybe_unused]] static bool %s(void);\n", procs[i].cname);
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
