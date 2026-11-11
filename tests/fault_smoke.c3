module rza_tests;

import std::io;

fn int faults_main() {
    defer (void)cleanup_temp_dir();
    int? status = fault_scenarios_run();
    if (catch status) {
        io::eprintn("FAULT_SMOKE FAILED");
        return 1;
    }
    if (status != 0) return status;
    io::printn("FAULT_SMOKE OK");
    return 0;
}
