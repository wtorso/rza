module rza_tests;

import std::io;

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintn("usage: rza_tests COMMAND [ARGS]");
        return 2;
    }
    if (args[1] == "function-style") return function_style_main(args[2..]);
    if (args[1] == "line-style") return source_line_style_main(args[2..]);
    if (args[1] == "artifacts") return artifacts_main();
    if (args[1] == "budgets") return budgets_main();
    if (args[1] == "fuzz") return fuzz_main();
    if (args[1] == "ownership") return ownership_main();
    if (args[1] == "faults") return faults_main();
    if (args[1] == "lsp") return lsp_main();
    io::eprintfn("unknown command: %s", args[1]);
    return 2;
}
