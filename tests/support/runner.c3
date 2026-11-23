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
    if (args[1] == "oracle") return oracle_main();
    if (args[1] == "numeric8-oracle") return numeric8_oracle_main();
    if (args[1] == "numeric16-oracle") return numeric16_oracle_main();
    if (args[1] == "numeric32-oracle") return numeric32_oracle_main();
    if (args[1] == "numeric64-oracle") return numeric64_oracle_main();
    if (args[1] == "float32-oracle") return float32_oracle_main();
    if (args[1] == "float64-oracle") return float64_oracle_main();
    if (args[1] == "faults") return faults_main();
    if (args[1] == "contracts") return proc_contracts_main();
    if (args[1] == "contract-fuzz") return contract_fuzz_main();
    if (args[1] == "lsp") return lsp_main();
    io::eprintfn("unknown command: %s", args[1]);
    return 2;
}
