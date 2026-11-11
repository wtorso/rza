mod scalar {
    include!("crc32c_core.rs");
}

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::{_mm_crc32_u64, _mm_crc32_u8};

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sse4.2")]
unsafe fn crc32c_hardware(data: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    let mut chunks = data.chunks_exact(8);
    for chunk in &mut chunks {
        let word = u64::from_le_bytes(chunk.try_into().unwrap());
        crc = _mm_crc32_u64(u64::from(crc), word) as u32;
    }
    for &byte in chunks.remainder() {
        crc = _mm_crc32_u8(crc, byte);
    }
    crc ^ u32::MAX
}

pub fn crc32c_uses_hardware() -> bool {
    #[cfg(target_arch = "x86_64")]
    {
        return is_x86_feature_detected!("sse4.2");
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        false
    }
}

pub fn crc32c_dispatch(data: &[u8]) -> u32 {
    #[cfg(target_arch = "x86_64")]
    if crc32c_uses_hardware() {
        return unsafe { crc32c_hardware(data) };
    }
    scalar::crc32c_software(data)
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_prepare() {}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_step() -> u64 {
    u64::from(crc32c_dispatch(&scalar::INPUT))
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_backend() -> u32 {
    u32::from(crc32c_uses_hardware())
}
