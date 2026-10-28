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
