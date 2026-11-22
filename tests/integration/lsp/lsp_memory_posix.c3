module rza_tests @feat(!WIN32);

import libc;
import std::io;
import std::io::file;
import std::os::posix;
import std::os::process;

char[256] statm_buf;

fn ulong? process_memory_bytes(Process* child) {
    String statm_path = string::tformat("/proc/%d/statm", child.child);
    File? maybe = file::open(statm_path, "rb");
    if (catch maybe) return process_memory_ps(child.child);
    File statm = maybe;
    defer (void)statm.close();
    sz count = statm.read(statm_buf[..])!;
    String[] fields = ((String)statm_buf[:count]).tsplit(" ", skip_empty: true);
    if (fields.len < 2) return TEST_ERROR~;
    ulong pages = fields[1].to_ulong()!;
    CLong page_size = posix::sysconf(posix::_SC_PAGESIZE);
    if (page_size <= 0) return TEST_ERROR~;
    return pages * (ulong)page_size;
}

fn ulong? process_memory_ps(Pid_t pid) {
    String pid_text = string::tformat("%d", pid);
    ProcessResult result = run_simple({ "ps", "-o", "rss=", "-p", pid_text })!;
    if (result.status != 0) return TEST_ERROR~;
    return result.stdout_text.trim().to_ulong()! * 1024;
}
