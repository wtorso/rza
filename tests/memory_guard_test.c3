module rez3asm;

import std::core::dstring;

fn void allocation_guard_lifecycle() @test {
    AllocationGuard guard;
    guard.init(mem);
    void* ptr = guard.acquire(16, ZERO, 0)!!;
    assert(ptr != null);
    ptr = guard.resize(ptr, 32, 0)!!;
    assert(ptr != null);
    guard.freeze();
    test::@error(guard.acquire(16, ZERO, 0), mem::OUT_OF_MEMORY);
    test::@error(guard.resize(ptr, 64, 0), mem::OUT_OF_MEMORY);
    guard.deinit();
    guard.release(ptr, false);
    test::@error(guard.acquire(16, ZERO, 0), mem::OUT_OF_MEMORY);
}

fn void scratch_memory_lifecycle() @test {
    ScratchMemory scratch;
    scratch.init(mem, 8);
    DString* value = scratch.acquire(8);
    assert(value != null);
    value.append_string("12345678");
    assert(scratch.acquire(1) == null);
    DString other = dstring::new(mem);
    defer other.free();
    assert(!scratch.release(&other));
    assert(!scratch.deinit());
    assert(scratch.release(value));
    DString* reused = scratch.acquire(1);
    assert(reused == value);
    assert(reused.len() == 0);
    assert(scratch.release(reused));
    assert(scratch.deinit());
}

fn void scratch_memory_capacity() @test {
    ScratchMemory scratch;
    scratch.init(mem, 4);
    assert(scratch.acquire(5) == null);
    DString* value = scratch.acquire(4);
    assert(value != null);
    value.append_string("12345");
    assert(!scratch.release(value));
    value.clear();
    assert(scratch.release(value));
    assert(scratch.deinit());
}

fn void scratch_memory_backing_stability() @test {
    init_workmem();
    ScratchMemory scratch;
    scratch.init(workmem, 16);
    void* blocker = workmem.acquire(16, NO_ZERO, 0)!!;
    assert(blocker != null);
    DString* value = scratch.acquire(16);
    char* backing = value.str_view().ptr;
    value.append_string("1234567890123456");
    assert(value.str_view().ptr == backing);
    value.append_string("7");
    assert(value.str_view().ptr != backing);
    value.clear();
    assert(!scratch.release(value));
}
