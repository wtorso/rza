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
fn int main(String[] args) {
    assert(args.len > 0);
    init_workmem();
    reset_state();
    list_guard.freeze();
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
