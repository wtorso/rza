mod scalar {
    include!("crc32c_core.rs");
}

pub use scalar::INPUT;

#[cfg_attr(not(test), unsafe(no_mangle))]
pub fn crc32c_software(data: &[u8]) -> u32 {
    scalar::crc32c_software(data)
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_prepare() {}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_step() -> u64 {
    u64::from(crc32c_software(&INPUT))
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_backend() -> u32 {
    0
}
