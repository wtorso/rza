module rez3asm;

import std::core::dstring;

fn void allocation_guard_lifecycle() @test {
    AllocationGuard guard;
    guard.init(mem);
    void* ptr = guard.acquire(16, ZERO, 0)!!;
    assert(ptr != null);
    assert(guard.acquire_count == 1);
    ptr = guard.resize(ptr, 32, 0)!!;
    assert(ptr != null);
    assert(guard.resize_count == 1);
    guard.freeze();
    test::@error(guard.acquire(16, ZERO, 0), mem::OUT_OF_MEMORY);
    test::@error(guard.resize(ptr, 64, 0), mem::OUT_OF_MEMORY);
    assert(guard.acquire_count == 1);
    assert(guard.resize_count == 1);
    guard.deinit();
    test::@error(guard.resize(ptr, 64, 0), mem::OUT_OF_MEMORY);
    assert(guard.resize_count == 1);
    guard.release(ptr, false);
    assert(guard.release_count == 1);
    test::@error(guard.acquire(16, ZERO, 0), mem::OUT_OF_MEMORY);
    assert(guard.acquire_count == 1);
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
    assert(!scratch.release(reused));
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

fn void allocation_guard_list_reset() @test {
    init_workmem();
    reset_state();
    list_guard.freeze();
    sz acquire_count = list_guard.acquire_count;
    sz resize_count = list_guard.resize_count;
    assert(acquire_count > 0);
    assert(list_guard.release_count == 0);
    reset_state();
    reset_state();
    assert(list_guard.acquire_count == acquire_count);
    assert(list_guard.resize_count == resize_count);
    assert(list_guard.release_count == 0);
    list_guard.deinit();
    frames.free();
    layouts.free();
    layout_fields.free();
    cells.free();
    meds.free();
    procs.free();
    cascades.free();
    blocks.free();
    labels.free();
    instrs.free();
    lsp_diags.free();
    g_state_inited = false;
    assert(list_guard.release_count == 11);
}
