const INPUT_BYTES: usize = 4096;
const TABLE_ENTRIES: usize = 256;

const fn make_input() -> [u8; INPUT_BYTES] {
    let mut data = [0; INPUT_BYTES];
    let mut i = 0;
    while i < INPUT_BYTES {
        data[i] = ((i * 37 + i / 7) & 255) as u8;
        i += 1;
    }
    data
}

static INPUT: [u8; INPUT_BYTES] = make_input();

const fn make_table() -> [u32; TABLE_ENTRIES] {
    let mut table = [0; TABLE_ENTRIES];
    let mut i = 0;
    while i < TABLE_ENTRIES {
        let mut crc = i as u32;
        let mut bit = 0;
        while bit < 8 {
            let low = crc & 1;
            crc >>= 1;
            if low != 0 {
                crc ^= 0x82f63b78;
            }
            bit += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
}

static TABLE: [u32; TABLE_ENTRIES] = make_table();

#[cfg_attr(not(test), unsafe(no_mangle))]
pub fn crc32c_table(data: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for &byte in data {
        crc = (crc >> 8) ^ TABLE[((crc ^ u32::from(byte)) & 255) as usize];
    }
    crc ^ u32::MAX
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_prepare() {}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_step() -> u64 {
    u64::from(crc32c_table(&INPUT))
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_backend() -> u32 {
    0
}
