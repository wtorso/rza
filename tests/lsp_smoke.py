#!/usr/bin/env python3
# LSP stdio smoke без VS Code: initialize, diagnostics, Full sync.
# Проверки: строки 1-based -> 0-based, malformed changes, close/reopen,
# 1000 ошибок + сводка, лимиты кадров, стабильный RSS на 2000 каскадах.
# Запуск: python3 tests/lsp_smoke.py [путь к rez3asm.exe]
import ctypes
import json
import os
import queue
import subprocess
import sys
import threading
import time
from ctypes import wintypes

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

EXE = sys.argv[1] if len(sys.argv) > 1 else "./rez3asm.exe"

BAD_URI = "file:///smoke-bad.rza"
GOOD_URI = "file:///smoke-good.rza"
BAD_TEXT = "cav a\n"
GOOD_TEXT = "cav m, field\ndecay m\nret\n"
CASCADE_TEXT = (
    "cav m, field\nres x, m, 8\nmed x_m, x, m\n"
    "casc c: x_m -> out[m]\n load %r0, [x_m + 0]\nendc\ndecay m\nret\n"
)
# Fixed build: 0; injected two-list leak: about 889 KiB per 2000 changes.
RSS_GROWTH_MAX = 512 * 1024

proc = subprocess.Popen(
    [EXE, "--lsp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

messages = queue.Queue()


def rss_bytes():
    if sys.platform == "win32":
        class Counters(ctypes.Structure):
            _fields_ = [
                ("cb", wintypes.DWORD),
                ("PageFaultCount", wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        kernel32 = ctypes.windll.kernel32
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        psapi = ctypes.windll.psapi
        psapi.GetProcessMemoryInfo.argtypes = [
            wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD,
        ]
        handle = kernel32.OpenProcess(0x1000, False, proc.pid)
        if not handle:
            raise RuntimeError("OpenProcess failed")
        try:
            counters = Counters()
            counters.cb = ctypes.sizeof(counters)
            if not ctypes.windll.psapi.GetProcessMemoryInfo(
                handle, ctypes.byref(counters), counters.cb
            ):
                raise RuntimeError("GetProcessMemoryInfo failed")
            return counters.WorkingSetSize
        finally:
            kernel32.CloseHandle(handle)
    try:
        with open(f"/proc/{proc.pid}/statm", "rb") as statm:
            return int(statm.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")
    except FileNotFoundError:
        rss_kib = subprocess.check_output(["ps", "-o", "rss=", "-p", str(proc.pid)])
        return int(rss_kib) * 1024


def reader():
    try:
        while True:
            headers = {}
            while True:
                line = proc.stdout.readline()
                if not line:
                    messages.put(None)
                    return
                line = line.strip()
                if not line:
                    break
                key, _, value = line.partition(b":")
                headers[key.strip().lower()] = value.strip()
            body = proc.stdout.read(int(headers[b"content-length"]))
            messages.put(json.loads(body))
    except Exception as e:  # сломанный фрейм — тест и так упадёт по таймауту/EOF
        print(f"reader crashed: {e}")
        messages.put(None)


threading.Thread(target=reader, daemon=True).start()

failures = 0


def check(name, cond, extra=""):
    global failures
    if cond:
        print(f"ok   - {name}")
    else:
        failures += 1
        print(f"FAIL - {name}{': ' + str(extra) if extra else ''}")


def frame(obj):
    body = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def send(obj):
    proc.stdin.write(frame(obj))
    proc.stdin.flush()


def recv(timeout=15):
    msg = messages.get(timeout=timeout)
    if msg is None:
        raise RuntimeError("server closed stdout unexpectedly")
    return msg


def initialize_request(ident):
    send({"jsonrpc": "2.0", "id": ident, "method": "initialize", "params": {}})
    return recv()


def did_open(uri, text, version):
    send({
        "jsonrpc": "2.0", "method": "textDocument/didOpen",
        "params": {"textDocument": {
            "uri": uri, "languageId": "rza", "version": version, "text": text,
        }},
    })
    return recv().get("params") or {}


def did_change(text, version):
    send({
        "jsonrpc": "2.0", "method": "textDocument/didChange",
        "params": {
            "textDocument": {"uri": GOOD_URI, "version": version},
            "contentChanges": [{"text": text}],
        },
    })
    return recv().get("params") or {}


def churn(count):
    for _ in range(count):
        did_change(CASCADE_TEXT, 2)


def initialize_checks():
    resp = initialize_request(1)
    result = resp.get("result") or {}
    check(
        "initialize: textDocumentSync = 1 (Full)",
        resp.get("id") == 1
        and (result.get("capabilities") or {}).get("textDocumentSync") == 1,
        json.dumps(resp),
    )
    info = result.get("serverInfo") or {}
    check(
        "initialize: serverInfo rez3-lsp/0.4.0",
        info.get("name") == "rez3-lsp" and info.get("version") == "0.4.0",
        json.dumps(info),
    )
    resp = initialize_request("x" * 300)
    check(
        "initialize: oversized id gets -32600, not a truncated id",
        resp.get("id") is None and (resp.get("error") or {}).get("code") == -32600,
        json.dumps(resp),
    )
    resp = initialize_request(1.5)
    check("initialize: fractional id is echoed exactly", resp.get("id") == 1.5,
          json.dumps(resp))


def id_protocol_checks():
    first = {"jsonrpc": "2.0", "id": 1.2345678901234567,
             "method": "initialize", "params": {}}
    second = {"jsonrpc": "2.0", "id": 1.25e20,
              "method": "initialize", "params": {}}
    proc.stdin.write(frame(first) + frame(second))
    proc.stdin.flush()
    first_resp = recv()
    second_resp = recv()
    check("initialize: high-precision id round trip",
          first_resp.get("id") == first["id"], json.dumps(first_resp))
    check("initialize: exponent id round trip",
          second_resp.get("id") == second["id"], json.dumps(second_resp))
    resp = initialize_request(True)
    check(
        "initialize: boolean id gets -32600",
        resp.get("id") is None and (resp.get("error") or {}).get("code") == -32600,
        json.dumps(resp),
    )
    request = {"jsonrpc": "2.0", "id": "fragmented",
               "method": "initialize", "params": {}}
    payload = frame(request)
    midpoint = len(payload) // 2
    proc.stdin.write(payload[:midpoint])
    proc.stdin.flush()
    time.sleep(0.02)
    proc.stdin.write(payload[midpoint:])
    proc.stdin.flush()
    resp = recv()
    check("framing: split request completes", resp.get("id") == "fragmented",
          json.dumps(resp))


def document_open_checks():
    params = did_open(BAD_URI, BAD_TEXT, 1)
    diags = params.get("diagnostics") or []
    check("bad.rza: ровно одна диагностика",
          params.get("uri") == BAD_URI and len(diags) == 1, json.dumps(params))
    diag = diags[0] if diags else {}
    check("bad.rza: code STRUCT", diag.get("code") == "STRUCT", json.dumps(diag))
    check("bad.rza: строка 0 (1-based 1 -> 0-based 0)",
          (diag.get("range") or {}).get("start", {}).get("line") == 0,
          json.dumps(diag.get("range")))
    check("bad.rza: severity=1, source=rez3asm",
          diag.get("severity") == 1 and diag.get("source") == "rez3asm",
          json.dumps(diag))
    params = did_open(GOOD_URI, GOOD_TEXT, 1)
    check("good.rza: diagnostics пустой",
          params.get("uri") == GOOD_URI and params.get("diagnostics") == [],
          json.dumps(params))


def rss_checks():
    churn(32)
    rss_before = rss_bytes()
    churn(2000)
    rss_after = rss_bytes()
    rss_growth = max(0, rss_after - rss_before)
    print(f"RSS before={rss_before}, after={rss_after}, growth={rss_growth}")
    check("LSP RSS: 2000 cascade changes stay bounded",
          rss_growth <= RSS_GROWTH_MAX,
          f"before={rss_before}, after={rss_after}, growth={rss_growth}")


def malformed_change_checks():
    for changes in ([], [{}], [None], [1], [[]]):
        send({
            "jsonrpc": "2.0", "method": "textDocument/didChange",
            "params": {
                "textDocument": {"uri": GOOD_URI, "version": 2},
                "contentChanges": changes,
            },
        })
    malformed_messages = [
        None, [],
        {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": None},
        {"jsonrpc": "2.0", "method": "textDocument/didChange", "params": None},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": None}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": []}},
    ]
    for message in malformed_messages:
        send(message)
    params = did_change(BAD_TEXT, 2)
    check("good.rza: didChange после memory churn публикует STRUCT",
          params.get("uri") == GOOD_URI and len(params.get("diagnostics") or []) == 1,
          json.dumps(params))


def close_reopen_checks():
    send({"jsonrpc": "2.0", "method": "textDocument/didClose",
          "params": {"textDocument": {"uri": GOOD_URI}}})
    params = recv().get("params") or {}
    check("good.rza: didClose очищает диагностику",
          params.get("uri") == GOOD_URI and params.get("diagnostics") == [],
          json.dumps(params))
    params = did_open(GOOD_URI, GOOD_TEXT, 3)
    check("good.rza: повторный didOpen работает",
          params.get("uri") == GOOD_URI and params.get("diagnostics") == [],
          json.dumps(params))


def diagnostic_limit_checks():
    params = did_change("x\n" * 1002, 4)
    diags = params.get("diagnostics") or []
    check("LSP diagnostics: 1000 errors + one summary",
          len(diags) == 1001 and diags[-1].get("message") == "2 diagnostics suppressed",
          f"count={len(diags)}")
    params = did_change(GOOD_TEXT, 5)
    check("LSP diagnostics: next change resets the summary",
          params.get("diagnostics") == [], json.dumps(params))
    params = did_change("€" * 200 + "\n", 6)
    diags = params.get("diagnostics") or []
    message = diags[0].get("message", "") if diags else ""
    check("LSP diagnostics: UTF-8 clip keeps whole codepoints",
          len(diags) == 1 and len(message.encode("utf-8")) <= 256
          and not message.endswith("�"),
          f"bytes={len(message.encode('utf-8'))}")


def shutdown_checks():
    send({"jsonrpc": "2.0", "id": 2, "method": "shutdown"})
    resp = recv()
    check("shutdown: ответ null",
          resp.get("id") == 2 and resp.get("result") is None and "error" not in resp,
          json.dumps(resp))
    send({"jsonrpc": "2.0", "method": "exit"})
    code = proc.wait(timeout=15)
    check("exit: сервер завершился с кодом 0", code == 0, f"code={code}")
    stderr = proc.stderr.read().decode(errors="replace").strip()
    if stderr:
        print(f"--- server stderr ---\n{stderr}\n---")


def oversize_checks():
    json_values = b"[" + b"0," * 65537 + b"0]"
    oversized = [
        ("header", b"X" * 9000, b"header too large"),
        ("JSON values", b"Content-Length: %d\r\n\r\n" % len(json_values)
         + json_values, b"JSON values exceeds static budget"),
        ("body", b"Content-Length: 16777217\r\n\r\n", b"body too large"),
        ("document", frame({
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {
                "uri": "file:///too-large.rza", "text": ";" * 1048577,
            }},
        }), b"document exceeds static budget"),
        ("URI", frame({
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {
                "uri": "file:///" + "u" * 1024, "text": "ret\n",
            }},
        }), b"URI exceeds static budget"),
        ("document slots", b"".join(frame({
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {
                "uri": f"file:///slot-{i}.rza", "text": "ret\n",
            }},
        }) for i in range(65)), b"document slots exceeds static budget"),
    ]
    for name, payload, diagnostic in oversized:
        result = subprocess.run([EXE, "--lsp"], input=payload,
                                capture_output=True, timeout=15)
        check(f"oversize {name}: controlled exit 2",
              result.returncode == 2 and diagnostic in result.stderr,
              result.stderr.decode(errors="replace"))


def main():
    initialize_checks()
    id_protocol_checks()
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    document_open_checks()
    rss_checks()
    malformed_change_checks()
    close_reopen_checks()
    diagnostic_limit_checks()
    shutdown_checks()
    oversize_checks()
    print("SMOKE OK" if failures == 0 else f"SMOKE FAILED ({failures})")
    return 0 if failures == 0 else 1


try:
    sys.exit(main())
except Exception as e:
    proc.kill()
    print(f"smoke crashed: {e}")
    sys.exit(1)
