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

extern fn CInt _setmode(CInt fd, CInt mode) @feat(WIN32);
const CInt RZA_O_BINARY @feat(WIN32) = 0x8000;

const String RZA_VERSION = "0.3.0";
const String USAGE_TEXT = "Usage:\n"
    "  rez3asm <file.rza> [--emit-c | --emit-lib] [-o <file.c>]\n"
    "  rez3asm --lsp\n"
    "  rez3asm --help\n"
    "  rez3asm --version\n"
    "\n"
    "Modes:\n"
    "  (default)       Validate the source without generating C.\n"
    "  --emit-c        Generate a standalone C23 program with main.\n"
    "  --emit-lib      Generate a C23 library without main for a C host.\n"
    "  -o <file.c>     Write C to a file; also enables C generation.\n"
    "  --lsp           Start the LSP server on standard input and output.\n"
    "  --help          Print this help and exit.\n"
    "  --version       Print the compiler version and exit.\n"
    "\n"
    "Without -o, generated C is written to standard output.\n"
    "\n"
    "Exit status:\n"
    "  0  Success.\n"
    "  1  Source validation failed.\n"
    "  2  Command-line usage or file I/O error.";

fn void metadata_binary_mode(bool error) {
    $if env::WIN32:
        CInt fd = error ? 2 : 1;
        CInt result = _setmode(fd, RZA_O_BINARY);
        assert(result != -1);
    $endif
}

fn void print_usage(bool error) {
    metadata_binary_mode(error);
    if (error) {
        io::eprintfn("%s", USAGE_TEXT);
        return;
    }
    io::printfn("%s", USAGE_TEXT);
}

fn int metadata_status(String[] args) {
    if (args.len != 2) return -1;
    if (args[1] == "--help") {
        print_usage(false);
        return 0;
    }
    if (args[1] != "--version") return -1;
    metadata_binary_mode(false);
    io::printfn("rez3asm %s", RZA_VERSION);
    return 0;
}

fn int main(String[] args) {
    assert(args.len > 0);
    int metadata = metadata_status(args);
    if (metadata >= 0) return metadata;
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
        print_usage(true);
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
