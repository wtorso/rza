#[path = "crc32c.rs"]
mod crc;
#[path = "crc32c_table.rs"]
mod crc_table;
#[path = "crc32c_intrinsic.rs"]
mod intrinsic;
#[path = "table.rs"]
mod table;
#[path = "protocol.rs"]
mod protocol;

#[test]
fn crc32c_standard_vector() {
    assert_eq!(crc::crc32c_software(b"123456789"), 0xe3069283);
    assert_eq!(crc_table::crc32c_table(b"123456789"), 0xe3069283);
}

#[test]
fn crc32c_hardware_matches_standard_vector() {
    assert_eq!(intrinsic::crc32c_dispatch(b"123456789"), 0xe3069283);
}

#[test]
fn crc32c_input_matches_formula() {
    crc::workload_prepare();
    assert_eq!(crc::workload_step(), 3_455_072_838);
    assert_eq!(crc::workload_step(), 3_455_072_838);
    crc_table::workload_prepare();
    assert_eq!(crc_table::workload_step(), 3_455_072_838);
    assert_eq!(crc_table::workload_step(), 3_455_072_838);
    intrinsic::workload_prepare();
    assert_eq!(intrinsic::workload_step(), 3_455_072_838);
}

#[test]
fn table_digest_is_derived_from_four_updates() {
    table::workload_prepare();
    assert_eq!(table::workload_step(), 462_336);
    assert_eq!(table::workload_step(), 462_336);
}

#[test]
fn selected_backend_is_explicit() {
    assert_eq!(crc::workload_backend(), 0);
    assert_eq!(crc_table::workload_backend(), 0);
    assert_eq!(table::workload_backend(), 0);
    assert_eq!(protocol::workload_backend(), 0);
    assert_eq!(
        intrinsic::workload_backend(),
        u32::from(intrinsic::crc32c_uses_hardware())
    );
}

#[test]
fn protocol_mixed_digest_is_repeatable() {
    protocol::workload_prepare();
    assert_eq!(protocol::workload_step(), 1_000_277_901_546_200);
    assert_eq!(protocol::workload_step(), 1_000_277_901_546_200);
}

#[test]
fn protocol_short_frame_uses_padded_crc() {
    let mut frame = [0u8; 9];
    frame[0] = 0xa5;
    frame[1] = 1;
    frame[4] = 42;
    let crc = 0x516b2987u32;
    frame[5] = crc as u8;
    frame[6] = (crc >> 8) as u8;
    frame[7] = (crc >> 16) as u8;
    frame[8] = (crc >> 24) as u8;
    assert_eq!(protocol::protocol_step(&frame), u64::from(crc) + 1000);
}

#[test]
fn protocol_truncated_frame_is_defined() {
    assert_eq!(protocol::protocol_step(&[0xa5, 1, 0, 0]), 1_000_000_000_000);
}
