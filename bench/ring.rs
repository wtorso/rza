use std::cell::RefCell;

#[derive(Clone, Copy)]
pub struct Ring {
    read_pos: usize,
    count: usize,
    input: u64,
    output: u64,
    full: u64,
    empty: u64,
    slots: [u64; 4],
    result: u64,
}

thread_local! {
    static RING: RefCell<Ring> = const {
        RefCell::new(Ring {
            read_pos: 0,
            count: 0,
            input: 0,
            output: 0,
            full: 0,
            empty: 0,
            slots: [0; 4],
            result: 0,
        })
    };
}

fn push(ring: &mut Ring) {
    if ring.count == 4 {
        ring.full += 1;
        return;
    }
    let write_pos = (ring.read_pos + ring.count) & 3;
    ring.slots[write_pos] = ring.input;
    ring.count += 1;
}

fn pop(ring: &mut Ring) {
    if ring.count == 0 {
        ring.empty += 1;
        return;
    }
    ring.output = ring.slots[ring.read_pos];
    ring.read_pos = (ring.read_pos + 1) & 3;
    ring.count -= 1;
    ring.result += ring.output;
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub fn ring_step(ring: &mut Ring) -> u64 {
    ring.read_pos = 0;
    ring.count = 0;
    ring.full = 0;
    ring.empty = 0;
    ring.result = 0;
    pop(ring);
    for request in 0..1024u64 {
        if (request & 7) < 5 {
            ring.input = request + 1;
            push(ring);
        } else {
            pop(ring);
        }
    }
    ring.result + ring.full + ring.empty
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_prepare() {
    RING.with(|_| {});
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_step() -> u64 {
    RING.with_borrow_mut(ring_step)
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_backend() -> u32 {
    0
}
