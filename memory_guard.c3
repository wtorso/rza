module rez3asm;

import std::core::mem;

enum AllocationPhase {
    INIT,
    STATIC,
    DEINIT,
}

struct AllocationGuard (Allocator) {
    Allocator backing;
    AllocationPhase phase;
}

fn void AllocationGuard.init(&self, Allocator backing) {
    *self = { .backing = backing, .phase = INIT };
    assert(self.phase == INIT);
}

fn void AllocationGuard.freeze(&self) {
    assert(self.phase == INIT);
    self.phase = STATIC;
    assert(self.phase == STATIC);
}

fn void AllocationGuard.deinit(&self) {
    assert(self.phase == STATIC);
    self.phase = DEINIT;
    assert(self.phase == DEINIT);
}

fn void*? AllocationGuard.acquire(&self, sz size, AllocInitType init_type,
                                   sz alignment) @dynamic {
    if (self.phase != INIT) return mem::OUT_OF_MEMORY~;
    return self.backing.acquire(size, init_type, alignment);
}

fn void*? AllocationGuard.resize(&self, void* ptr, sz new_size,
                                 sz alignment) @dynamic {
    if (self.phase != INIT) return mem::OUT_OF_MEMORY~;
    return self.backing.resize(ptr, new_size, alignment);
}

fn void AllocationGuard.release(&self, void* ptr, bool aligned) @dynamic {
    assert(self.phase == DEINIT);
    assert(ptr != null);
    self.backing.release(ptr, aligned);
}
