module rez3asm;

fn void output_writer_exact_capacity() @test {
    init_workmem();
    Output out;
    out.init(2, 4);
    out.append_string("ab");
    out.appendf("%s", "cd");
    assert(out.len() == 4);
    assert(out.str_view() == "abcd");
    assert(!out.overflow);
    out.append_string("e");
    assert(out.overflow);
    assert(out.len() == 4);
}

fn void output_writer_formatted_overflow() @test {
    init_workmem();
    Output out;
    out.init(1, 3);
    out.appendf("%s", "abcd");
    assert(out.overflow);
    assert(out.len() <= 3);
}

fn void output_writer_full_budget() @test {
    init_workmem();
    Output out;
    out.init(OUTPUT_BYTES_MAX, OUTPUT_BYTES_MAX);
    sz initial_used = work_arena.mark();
    char[4096] chunk;
    for (sz i = 0; i < chunk.len; i++) chunk[i] = 'x';
    for (int i = 0; i < OUTPUT_BYTES_MAX / 4096; i++) {
        out.append_string((String)chunk[..]);
    }
    assert(out.len() == OUTPUT_BYTES_MAX);
    assert(!out.overflow);
    out.append_string("x");
    assert(out.overflow);
    assert(work_arena.mark() == initial_used);
    assert(out.len() == OUTPUT_BYTES_MAX);
}
