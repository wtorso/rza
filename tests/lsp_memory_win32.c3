module rza_tests @feat(WIN32) @link("psapi");

import std::os::process;
import std::os::win32;

struct ProcessMemoryCounters {
    Win32_DWORD cb;
    Win32_DWORD page_fault_count;
    sz peak_working_set_size;
    sz working_set_size;
    sz quota_peak_paged_pool_usage;
    sz quota_paged_pool_usage;
    sz quota_peak_non_paged_pool_usage;
    sz quota_non_paged_pool_usage;
    sz pagefile_usage;
    sz peak_pagefile_usage;
}

extern fn Win32_BOOL get_process_memory_info(Win32_HANDLE process,
    ProcessMemoryCounters* counters, Win32_DWORD size) @cname("GetProcessMemoryInfo");

fn ulong? process_memory_bytes(Process* child) {
    ProcessMemoryCounters counters;
    counters.cb = (Win32_DWORD)ProcessMemoryCounters::size;
    if (!get_process_memory_info(child.hProcess, &counters, counters.cb)) {
        return TEST_ERROR~;
    }
    return (ulong)counters.pagefile_usage;
}
