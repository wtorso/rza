const INPUT_BYTES: usize = 4096;
const QUOTA: u64 = 1024;
const VARIANT: u8 = 0;

const fn crc32c(data: &[u8], start: usize, size: usize) -> u32 {
    let mut crc = u32::MAX;
    let mut index = 0;
    while index < size {
        crc ^= data[start + index] as u32;
        let mut bit = 0;
        while bit < 8 {
            let low = crc & 1;
            crc >>= 1;
            if low != 0 {
                crc ^= 0x82f63b78;
            }
            bit += 1;
        }
        index += 1;
    }
    !crc
}

const fn put32le(output: &mut [u8; 16], start: usize, value: u32) {
    let mut index = 0;
    while index < 4 {
        output[start + index] = (value >> (index * 8)) as u8;
        index += 1;
    }
}

const fn make_input() -> [u8; INPUT_BYTES] {
    let mut output = [0u8; INPUT_BYTES];
    let mut used = 0;
    let mut frame = 0u32;
    while used < INPUT_BYTES {
        let mut data = [0u8; 16];
        let length = if VARIANT == 1 {
            8
        } else if VARIANT == 2 {
            1
        } else {
            1 + frame as usize % 8
        };
        let frame_size = length + 8;
        data[0] = 0xa5;
        data[1] = length as u8;
        data[2] = frame as u8;
        let mut index = 0;
        while index < length {
            data[4 + index] = (frame.wrapping_mul(17) + (index as u32) * 31) as u8;
            index += 1;
        }
        let mut crc = crc32c(&data, 4, 8);
        if (VARIANT == 0 || VARIANT == 3) && frame % 11 == 10 {
            crc ^= 1;
        }
        if (VARIANT == 0 || VARIANT == 3) && frame % 13 == 12 {
            data[2] = data[2].wrapping_add(1);
        }
        put32le(&mut data, 4 + length, crc);
        if (VARIANT == 0 || VARIANT == 3) && frame % 17 == 16 {
            data[1] = 255;
        }
        if VARIANT == 3 && frame == 0 {
            data[1] = 255;
        }
        let remaining = INPUT_BYTES - used;
        let copy = if frame_size < remaining { frame_size } else { remaining };
        let mut index = 0;
        while index < copy {
            output[used + index] = data[index];
            index += 1;
        }
        used += copy;
        frame += 1;
    }
    output
}

static INPUT: [u8; INPUT_BYTES] = make_input();

struct State {
    accepted: u64,
    invalid: u64,
    dropped: u64,
    truncated: u64,
    quota_faults: u64,
    total_payload: u64,
    expected_sequence: u64,
    digest: u64,
    ring_count: u64,
    ring_read: u64,
    ring: [[u8; 8]; 4],
}

impl State {
    fn new() -> Self {
        Self {
            accepted: 0,
            invalid: 0,
            dropped: 0,
            truncated: 0,
            quota_faults: 0,
            total_payload: 0,
            expected_sequence: 0,
            digest: 0,
            ring_count: 0,
            ring_read: 0,
            ring: [[0; 8]; 4],
        }
    }

    fn pop(&mut self) {
        self.digest = self.digest.wrapping_add(crc32c(&self.ring[self.ring_read as usize], 0, 8) as u64);
        self.ring_read = (self.ring_read + 1) & 3;
        self.ring_count -= 1;
    }

    fn finish(mut self) -> u64 {
        while self.ring_count > 0 {
            self.pop();
        }
        self.digest
            .wrapping_add(self.accepted * 1000)
            .wrapping_add(self.invalid * 1_000_000)
            .wrapping_add(self.dropped * 1_000_000_000)
            .wrapping_add(self.truncated * 1_000_000_000_000)
            .wrapping_add(self.quota_faults * 1_000_000_000_000_000)
    }
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub fn protocol_step(input: &[u8]) -> u64 {
    let mut state = State::new();
    let mut offset = 0usize;
    while offset < input.len() {
        if input.len() - offset < 4 {
            state.truncated += 1;
            break;
        }
        if input[offset] != 0xa5 {
            state.invalid += 1;
            offset += 1;
            continue;
        }
        let length = input[offset + 1] as usize;
        if length > 8 {
            state.invalid += 1;
            offset += 1;
            continue;
        }
        let next = offset + length + 8;
        if next > input.len() {
            state.truncated += 1;
            break;
        }
        let current = offset;
        offset = next;
        let sequence = input[current + 2] as u64;
        let sequence_ok = sequence == state.expected_sequence;
        state.expected_sequence = (sequence + 1) & 255;
        if !sequence_ok {
            state.invalid += 1;
        }
        if input[current + 3] != 0 {
            state.invalid += 1;
            continue;
        }
        state.total_payload += length as u64;
        if state.total_payload > QUOTA {
            state.quota_faults += 1;
            break;
        }
        let mut scratch = [0u8; 8];
        let mut index = 0;
        while index < length {
            scratch[index] = input[current + 4 + index];
            index += 1;
        }
        let expected_crc = (input[current + 4 + length] as u32)
            | ((input[current + 5 + length] as u32) << 8)
            | ((input[current + 6 + length] as u32) << 16)
            | ((input[current + 7 + length] as u32) << 24);
        if crc32c(&scratch, 0, 8) != expected_crc {
            state.invalid += 1;
            continue;
        }
        state.accepted += 1;
        if state.ring_count < 4 {
            let write = ((state.ring_read + state.ring_count) & 3) as usize;
            state.ring[write] = scratch;
            state.ring_count += 1;
        } else {
            state.dropped += 1;
        }
        if state.accepted % 3 == 0 && state.ring_count > 0 {
            state.pop();
        }
    }
    state.finish()
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_prepare() {}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_step() -> u64 {
    let size = if VARIANT == 2 { INPUT_BYTES - 2 } else { INPUT_BYTES };
    protocol_step(&INPUT[..size])
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_backend() -> u32 {
    0
}
