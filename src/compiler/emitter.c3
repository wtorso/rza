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

// Глобальный медиатор инициализируется при создании res или OUT.
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

fn void emit_bounds_guard(Output* out, int ind, Instr* ins) {
    if (ins.c < 0) return;
    Cell* cell = validated_access_cell(ins);
    pad(out, ind);
    if (cell.layout >= 0) {
        out.appendf("if (r%d < 0 || (uint64_t)r%d >= %d) {\n",
                    ins.c, ins.c, cell.element_count);
    } else {
        int width = ins.flag ? 1 : 8;
        out.appendf("if (!rez_cell_bounds(%s, r%d, %d)) {\n",
                    meds[ins.x].cname, ins.c, width);
    }
    pad(out, ind + 1);
    out.appendf("fprintf(stderr, \"FAULT line %d: out of bounds %s\\n\");\n",
                ins.line, meds[ins.x].name);
    pad(out, ind + 1);
    out.append_string("exit(1);\n");
    pad(out, ind);
    out.append_string("}\n");
}

fn void emit_load(Output* out, int ind, Instr* ins, bool in_casc) {
    DString* oex = load_offset_scratch.acquire(OFFSET_STRING_BYTES);
    assert(oex != null);
    defer assert(load_offset_scratch.release(oex));
    append_access_offset(oex, ins);
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
    DString* sex = store_offset_scratch.acquire(OFFSET_STRING_BYTES);
    assert(sex != null);
    defer assert(store_offset_scratch.release(sex));
    append_access_offset(sex, ins);
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
        out.appendf("*(unsigned char*)((char*)%s + %s) = (unsigned char)r%d;",
                    ptr, sex.str_view(), ins.a);
    } else {
        out.appendf("memcpy((char*)%s + %s, &r%d, 8);",
                    ptr, sex.str_view(), ins.a);
    }
    out.append_string(in_casc ? "\n" : " }\n");
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
        out.appendf("r%d = r%d < %s;\n", ins.a, ins.b, rhs.str_view());
        return;
    }
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
    pad(out, ind + 1);
    out.appendf("fprintf(stderr, \"FAULT line %d: async task %s already pending\\n\");\n",
                ca.line, ca.name);
    pad(out, ind + 1);
    out.append_string("exit(1);\n");
    pad(out, ind);
    out.append_string("}\n");
    for (int i = 0; i < ca.med_count; i++) {
        int mi = ca.med_idxs[i];
        pad(out, ind);
        out.appendf("if (!rez_deref_cell(%s)) {\n", meds[mi].cname);
        pad(out, ind + 1);
        out.appendf("fprintf(stderr, \"ABORT line %d: cascade %s: "
                    "dead mediator %s\\n\");\n", ca.line, ca.name, meds[mi].name);
        pad(out, ind + 1);
        out.appendf("goto casc_end_%d;\n", ca.seq);
        pad(out, ind);
        out.append_string("}\n");
    }
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
    pad(out, ind + 1);
    out.appendf("fprintf(stderr, \"FAULT line %d: async queue full\\n\");\n", ca.line);
    pad(out, ind + 1);
    out.append_string("exit(1);\n");
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

fn void emit_casc_instructions(Output* out, int ind, Cascade* ca) {
    for (sz i = 0; i < instrs.len(); i++) {
        Instr* ins = &instrs[i];
        if (ins.block != ca.block || ins.op == Op.ENDC) continue;
        switch (ins.op) {
            case Op.LABEL: emit_label(out, ind, ins);
            case Op.LOAD: emit_load(out, ind, ins, true);
            case Op.STORE: emit_store(out, ind, ins, true);
            case Op.MOV:
                pad(out, ind);
                if (ins.flag) { if (ins.immediate == -9223372036854775807 - 1) {
                    out.appendf("r%d = INT64_MIN;\n", ins.a);
                } else {
                    out.appendf("r%d = %d;\n", ins.a, ins.immediate);
                } }
                else { out.appendf("r%d = r%d;\n", ins.a, ins.b); }
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

fn void emit_async_publish(Output* out, int ind, int cell) {
    for (int i = 0; i < cells[cell].med_count; i++) {
        int mi = cells[cell].med_idxs[i];
        pad(out, ind);
        out.appendf("%s = rez_issue_cell(%s, %s, %s, %d);\n",
                    meds[mi].cname, fexpr(meds[mi].owner),
                    fexpr(cells[cell].home), cells[cell].cname, cells[cell].size);
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
                mask |= 1u << ins.a;
                if (!ins.flag) mask |= 1u << ins.b;
            case Op.ALU3:
                mask |= 1u << ins.a;
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
    out.appendf("static bool ac_run_%d(void *context) {\n", ca.seq);
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
        out.appendf("        fprintf(stderr, \"ABORT line %d: cascade %s: "
                    "dead mediator %s\\n\");\n", ca.line, ca.name, meds[mi].name);
        out.appendf("        ac_pending_%d = false;\n", ca.seq);
        out.append_string("        return false;\n");
        out.append_string("    }\n");
    }
    emit_casc_instructions(out, 1, ca);
    out.appendf("    ac_pending_%d = false;\n", ca.seq);
    emit_async_publish(out, 1, ca.out_cell);
    out.append_string("    return true;\n");
    out.append_string("}\n\n");
}

fn void emit_async_callbacks(Output* out) {
    for (sz i = 0; i < cascades.len(); i++) {
        if (cascades[i].is_async) emit_async_callback(out, (int)i);
    }
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
    if (g_lib_mode) { out.appendf("rza_%s();\n", procs[ins.x].name); }
    else { out.appendf("%s();\n", procs[ins.x].cname); }
}

fn void emit_await(Output* out, int ind, Instr* ins) {
    pad(out, ind);
    out.appendf("r%d = (int64_t)rez_async_drain(&g_async);\n", ins.a);
}

fn bool is_async_block(int block) {
    if (block < 0 || block >= (int)blocks.len()) return false;
    if (blocks[block].kind != 2) return false;
    int ci = blocks[block].aux - 1;
    assert(ci >= 0);
    assert(ci < (int)cascades.len());
    return cascades[ci].is_async;
}

fn void emit_body(Output* out, int func) {
    int ind = 1;
    assert(func <= (int)procs.len());
    for (sz i = 0; i < instrs.len(); i++) {
        Instr* ins = &instrs[i];
        if (ins.func != func || is_async_block(ins.block)) continue;
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
                    if (ins.immediate == -9223372036854775807 - 1) {
                    out.appendf("r%d = INT64_MIN;\n", ins.a);
                } else {
                    out.appendf("r%d = %d;\n", ins.a, ins.immediate);
                }
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
            case Op.CALL: emit_call(out, ind, ins);
            case Op.AWAIT: emit_await(out, ind, ins);
            case Op.RET:
                // Общий epilogue сначала делает drain, возврат происходит
                // только после него: top-level ret не обходит очередь.
                // ret процедуры закрывается emit_proc.
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
    out.append_string("    (void)rez_async_drain(&g_async);\n");
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
    out.append_string("    (void)rez_async_drain(&g_async);\n");
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
    out.append_string("    (void)rez_async_drain(&g_async);\n");
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
        if (!cells[ci].async_out) {
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
    out.append_string("uint64_t rza_await(void) { return rez_async_drain(&g_async); }\n");
    out.append_string("void *rza_arena_alloc(RezCavity *cavity, uint64_t size) "
                      "{ return rez_cell_z(cavity, size); }\n");
    out.append_string("void *rza_deref_cell(RezCellMed mediator) "
                      "{ return rez_deref_cell(mediator); }\n");
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
    }
    for (sz i = 0; i < procs.len(); i++) {
        assert(procs[i].frame >= 0);
        assert(procs[i].frame < (int)frames.len());
        assert(procs[i].block >= 0);
        assert(procs[i].block < (int)blocks.len());
        assert(procs[i].cname.len > 0);
        out.appendf("static RezCavity %s;\n", frames[procs[i].frame].cname);
        out.appendf("_Alignas(REZ_ALIGNMENT) static char A_%s[%d];\n",
                    frames[procs[i].frame].cname, frames[procs[i].frame].cap);
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
    out.append_string("/* Source-SHA256: ");
    foreach (byte : source_hash) out.appendf("%02x", (uint)byte);
    out.append_string(" */\n");
    out.append_string("/* Generated by rez3asm (C3) — REZ3-ASM -> C23 */\n");
    out.append_string("#include <stdio.h>\n");
    out.append_string("#include <stdint.h>\n");
    out.append_string("#include <stdlib.h>\n");
    out.append_string("#include \"rez3ext.h\"\n\n");
    emit_static_storage(&out);
    out.append_string("RezAsyncQueue g_async;\n\n");
    emit_async_callbacks(&out);
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
