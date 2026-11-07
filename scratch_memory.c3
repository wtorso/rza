module rez3asm;

import std::core::dstring;

struct ScratchMemory {
    DString buffer;
    char* backing_ptr;
    sz capacity_bytes;
    bool busy;
}

fn void ScratchMemory.init(&self, Allocator allocator, sz capacity_bytes) {
    assert(capacity_bytes > 0);
    *self = {
        .buffer = dstring::new_with_capacity(allocator, capacity_bytes),
        .capacity_bytes = capacity_bytes,
        .busy = false,
    };
    self.backing_ptr = self.buffer.str_view().ptr;
    assert(self.buffer.capacity() >= self.capacity_bytes);
    assert(self.backing_ptr != null);
    assert(!self.busy);
}

fn DString* ScratchMemory.acquire(&self, sz required_bytes) {
    if (self.busy || required_bytes == 0) return null;
    if (required_bytes > self.capacity_bytes) return null;
    if (self.buffer.str_view().ptr != self.backing_ptr) return null;
    assert(self.buffer.capacity() >= self.capacity_bytes);
    self.buffer.clear();
    self.busy = true;
    assert(self.buffer.len() == 0);
    return &self.buffer;
}

fn bool ScratchMemory.release(&self, DString* borrowed) {
    if (!self.busy || borrowed != &self.buffer) return false;
    if (self.buffer.str_view().ptr != self.backing_ptr) return false;
    if (self.buffer.len() > self.capacity_bytes) return false;
    if (self.buffer.capacity() < self.capacity_bytes) return false;
    self.buffer.clear();
    self.busy = false;
    assert(!self.busy);
    return true;
}

fn bool ScratchMemory.deinit(&self) {
    if (self.busy) return false;
    if (self.buffer.capacity() < self.capacity_bytes) return false;
    self.buffer.free();
    self.capacity_bytes = 0;
    assert(!self.busy);
    assert(!self.buffer);
    return true;
}
