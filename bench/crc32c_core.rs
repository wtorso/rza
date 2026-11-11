const INPUT_BYTES: usize = 4096;

const fn make_input() -> [u8; INPUT_BYTES] {
    let mut data = [0; INPUT_BYTES];
    let mut i = 0;
    while i < INPUT_BYTES {
        data[i] = ((i * 37 + i / 7) & 255) as u8;
        i += 1;
    }
    data
}

pub static INPUT: [u8; INPUT_BYTES] = make_input();

pub fn crc32c_software(data: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for &byte in data {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            let low = crc & 1;
            crc >>= 1;
            if low != 0 {
                crc ^= 0x82f63b78;
            }
        }
    }
    crc ^ u32::MAX
}
