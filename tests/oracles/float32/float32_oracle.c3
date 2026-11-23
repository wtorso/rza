module rza_tests;

import std::io;

fn int float32_oracle_main() {
    int status = float_oracle_main(FloatWidth.F32);
    if (status == 0) io::printn("FLOAT32_ORACLE OK (128 programs)");
    return status;
}
