#[path = "crc32c.rs"]
mod crc;
#[path = "crc32c_table.rs"]
mod crc_table;
#[path = "crc32c_intrinsic.rs"]
mod intrinsic;
#[path = "table.rs"]
mod table;

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
    assert_eq!(
        intrinsic::workload_backend(),
        u32::from(intrinsic::crc32c_uses_hardware())
    );
}
