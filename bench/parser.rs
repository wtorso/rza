const INPUT_BYTES: usize = 4096;
const PATTERN: &[u8; 16] = b"abc=12;#x=4;z=9;";

const fn make_input() -> [u8; INPUT_BYTES] {
    let mut data = [0; INPUT_BYTES];
    let mut i = 0;
    while i < INPUT_BYTES {
        data[i] = PATTERN[i % PATTERN.len()];
        i += 1;
    }
    data
}

static INPUT: [u8; INPUT_BYTES] = make_input();

fn is_alpha(byte: u8) -> bool {
    let upper = byte & 223;
    upper >= b'A' && upper <= b'Z'
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub fn parse(data: &[u8]) -> u64 {
    let mut state = 0;
    let mut value = 0u64;
    let mut records = 0u64;
    let mut invalid = 0u64;
    let mut sum = 0u64;
    for &byte in data {
        let alpha = is_alpha(byte);
        let digit = byte.is_ascii_digit();
        if state == 0 {
            if alpha { state = 1; } else { invalid += 1; }
        } else if state == 1 {
            if alpha || digit {
                continue;
            }
            if byte == b'=' {
                state = 2;
                value = 0;
            } else {
                invalid += 1;
                state = 0;
                value = 0;
            }
        } else if digit {
            value = value * 10 + u64::from(byte - b'0');
        } else if byte == b';' {
            records += 1;
            sum += value;
            value = 0;
            state = 0;
        } else {
            invalid += 1;
            state = 0;
            value = 0;
        }
    }
    records * 1_000_000 + invalid * 1000 + sum
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_prepare() {}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_step() -> u64 {
    parse(&INPUT)
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_backend() -> u32 {
    0
}
