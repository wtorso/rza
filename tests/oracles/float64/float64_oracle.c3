module rza_tests;

import std::io;

fn int float64_oracle_main() {
    int status = float_oracle_main(FloatWidth.F64);
    if (status == 0) io::printn("FLOAT64_ORACLE OK (128 programs)");
    return status;
}
