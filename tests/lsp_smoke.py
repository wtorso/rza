#!/usr/bin/env python3
# lsp_smoke.py — smoke-тест LSP-сервера `rez3asm --lsp` без VS Code.
#
# Говорит с сервером по stdio (Content-Length framing, пишется руками).
# Сценарий:
#   initialize            -> capabilities.textDocumentSync == 1 (Full),
#                            serverInfo = rez3-lsp/0.4.0
#   didOpen bad.rza       -> ровно одна диагностика, code STRUCT, строка 0
#     Текст "cav a": у cav два операнда (SPEC §2: cav NAME, PARENT) —
#     чекер пишет "VIOLATION line 1 [STRUCT]: bad operands for cav"
#     (тот же случай, что tests/viol_extra_ops.rza); LSP переводит
#     1-based строку 1 в 0-based 0.
#   didOpen good.rza      -> diagnostics пустой
#     Текст "cav m, field / decay m / ret" — минимальная легальная
#     программа (как hello из docs/GUIDE.md, но без вывода).
#   didChange/didClose/didOpen -> STRUCT, очистка, снова пустая диагностика.
#   shutdown + exit       -> сервер завершается с кодом 0.
#
# Запуск: python3 tests/lsp_smoke.py [путь к rez3asm.exe]   (из rez3-asm/)
import json
import queue
import subprocess
import sys
import threading

# Windows-консоль по умолчанию не в UTF-8 — имена проверок русские
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

EXE = sys.argv[1] if len(sys.argv) > 1 else "./rez3asm.exe"

BAD_URI = "file:///smoke-bad.rza"
GOOD_URI = "file:///smoke-good.rza"
BAD_TEXT = "cav a\n"
GOOD_TEXT = "cav m, field\ndecay m\nret\n"

proc = subprocess.Popen(
    [EXE, "--lsp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

messages = queue.Queue()


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


def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    proc.stdin.flush()


def recv(timeout=15):
    msg = messages.get(timeout=timeout)
    if msg is None:
        raise RuntimeError("server closed stdout unexpectedly")
    return msg


def main():
    send({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"processId": None, "capabilities": {}},
    })
    resp = recv()
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
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    send({
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": BAD_URI,
                "languageId": "rza",
                "version": 1,
                "text": BAD_TEXT,
            }
        },
    })
    params = recv().get("params") or {}
    diags = params.get("diagnostics") or []
    check(
        "bad.rza: ровно одна диагностика",
        params.get("uri") == BAD_URI and len(diags) == 1,
        json.dumps(params),
    )
    d = diags[0] if diags else {}
    check("bad.rza: code STRUCT", d.get("code") == "STRUCT", json.dumps(d))
    check(
        "bad.rza: строка 0 (1-based 1 -> 0-based 0)",
        (d.get("range") or {}).get("start", {}).get("line") == 0,
        json.dumps(d.get("range")),
    )
    check(
        "bad.rza: severity=1, source=rez3asm",
        d.get("severity") == 1 and d.get("source") == "rez3asm",
        json.dumps(d),
    )

    send({
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": GOOD_URI,
                "languageId": "rza",
                "version": 1,
                "text": GOOD_TEXT,
            }
        },
    })
    params = recv().get("params") or {}
    check(
        "good.rza: diagnostics пустой",
        params.get("uri") == GOOD_URI and params.get("diagnostics") == [],
        json.dumps(params),
    )

    for i in range(256):
        send({
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": f"file:///churn-{i:04d}.rza",
                    "languageId": "rza",
                    "version": 1,
                    "text": GOOD_TEXT,
                }
            },
        })
        recv()

    send({
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
            "textDocument": {"uri": GOOD_URI, "version": 2},
            "contentChanges": [{"text": BAD_TEXT}],
        },
    })
    params = recv().get("params") or {}
    check(
        "good.rza: didChange после memory churn публикует STRUCT",
        params.get("uri") == GOOD_URI and len(params.get("diagnostics") or []) == 1,
        json.dumps(params),
    )
    send({
        "jsonrpc": "2.0",
        "method": "textDocument/didClose",
        "params": {"textDocument": {"uri": GOOD_URI}},
    })
    params = recv().get("params") or {}
    check(
        "good.rza: didClose очищает диагностику",
        params.get("uri") == GOOD_URI and params.get("diagnostics") == [],
        json.dumps(params),
    )
    send({
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": GOOD_URI,
                "languageId": "rza",
                "version": 3,
                "text": GOOD_TEXT,
            }
        },
    })
    params = recv().get("params") or {}
    check(
        "good.rza: повторный didOpen работает",
        params.get("uri") == GOOD_URI and params.get("diagnostics") == [],
        json.dumps(params),
    )

    send({"jsonrpc": "2.0", "id": 2, "method": "shutdown"})
    resp = recv()
    check(
        "shutdown: ответ null",
        resp.get("id") == 2 and resp.get("result") is None and "error" not in resp,
        json.dumps(resp),
    )
    send({"jsonrpc": "2.0", "method": "exit"})
    code = proc.wait(timeout=15)
    check("exit: сервер завершился с кодом 0", code == 0, f"code={code}")

    stderr = proc.stderr.read().decode(errors="replace").strip()
    if stderr:
        print(f"--- server stderr ---\n{stderr}\n---")
    print("SMOKE OK" if failures == 0 else f"SMOKE FAILED ({failures})")
    return 0 if failures == 0 else 1


try:
    sys.exit(main())
except Exception as e:
    proc.kill()
    print(f"smoke crashed: {e}")
    sys.exit(1)
