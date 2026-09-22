#!/usr/bin/env node
/*
 * smoke-test.js — юнит-проверка rez3-lsp.js без VS Code.
 *
 * Говорит с сервером по stdio (spawn), шлёт initialize + didOpen с
 * текстом tests/viol_i2.rza, затем didChange с текстом tests/fib.rza.
 * Проверяет:
 *   - viol_i2  -> есть диагностика с code "I2" на строке 5 (1-based);
 *   - fib      -> diagnostics пустой;
 *   - shutdown/exit завершают сервер с кодом 0.
 *
 * Запуск: node smoke-test.js
 */
"use strict";

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const LSP_DIR = __dirname;
const ROOT = path.resolve(LSP_DIR, "..");
const SERVER = path.join(LSP_DIR, "rez3-lsp.js");
const VIOL_FILE = path.join(ROOT, "tests", "viol_i2.rza");
const FIB_FILE = path.join(ROOT, "tests", "fib.rza");
const DOC_URI = "file:///smoke-test.rza";

// Путь к транспайлеру: rez3asm.exe (C3; собирается шагом 0 run_tests.sh).
function resolveTranspiler() {
  const exe = path.join(ROOT, "rez3asm.exe");
  if (!fs.existsSync(exe)) {
    console.error(`FAIL - transpiler not found: ${exe} (run: bash run_tests.sh)`);
    process.exit(1);
  }
  return { transpilerPath: exe };
}

let failures = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log(`ok   - ${name}`);
  } else {
    failures++;
    console.log(`FAIL - ${name}${extra ? `: ${extra}` : ""}`);
  }
}

// --- минимальный LSP-клиент ------------------------------------------------

const child = spawn(process.execPath, [SERVER], {
  stdio: ["pipe", "pipe", "pipe"],
});

let outBuf = Buffer.alloc(0);
const pending = new Map(); // id -> resolve
let nextId = 1;
const diagnosticsWaiters = [];

child.stdout.on("data", (chunk) => {
  outBuf = Buffer.concat([outBuf, chunk]);
  for (;;) {
    const headerEnd = outBuf.indexOf("\r\n\r\n");
    if (headerEnd === -1) break;
    const header = outBuf.slice(0, headerEnd).toString("latin1");
    const m = /Content-Length:\s*(\d+)/i.exec(header);
    if (!m) break;
    const len = parseInt(m[1], 10);
    const start = headerEnd + 4;
    if (outBuf.length < start + len) break;
    const msg = JSON.parse(outBuf.slice(start, start + len).toString("utf8"));
    outBuf = outBuf.slice(start + len);
    onMessage(msg);
  }
});

let serverStderr = "";
child.stderr.on("data", (d) => {
  serverStderr += d.toString("utf8");
});

function send(obj) {
  const body = Buffer.from(JSON.stringify(obj), "utf8");
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
}

function request(method, params) {
  const id = nextId++;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    send({ jsonrpc: "2.0", id, method, params });
  });
}

function notify(method, params) {
  send({ jsonrpc: "2.0", method, params });
}

function onMessage(msg) {
  if (msg.id !== undefined && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
    return;
  }
  if (msg.method === "textDocument/publishDiagnostics") {
    const w = diagnosticsWaiters.slice();
    for (const waiter of w) waiter(msg.params);
  }
  // Ответы на server->client запросы (workspace/configuration и т.п.)
  if (msg.id !== undefined && msg.method) {
    send({ jsonrpc: "2.0", id: msg.id, result: null });
  }
}

function waitDiagnostics() {
  return new Promise((resolve) => {
    const waiter = (params) => {
      const i = diagnosticsWaiters.indexOf(waiter);
      if (i !== -1) diagnosticsWaiters.splice(i, 1);
      resolve(params);
    };
    diagnosticsWaiters.push(waiter);
  });
}

// --- сценарий ---------------------------------------------------------------

async function main() {
  const transpiler = resolveTranspiler();
  const initResp = await request("initialize", {
    processId: process.pid,
    rootUri: `file://${ROOT.replace(/\\/g, "/")}`,
    capabilities: {},
    initializationOptions: {
      extensionRoot: path.join(ROOT, "editors", "vscode"),
      ...transpiler,
    },
  });
  check(
    "initialize: textDocumentSync = 1 (full)",
    initResp.result &&
      initResp.result.capabilities &&
      initResp.result.capabilities.textDocumentSync === 1,
    JSON.stringify(initResp.result)
  );
  notify("initialized", {});

  // 1. didOpen с текстом viol_i2.rza -> ждём диагностику [I2] на строке 5.
  const violText = fs.readFileSync(VIOL_FILE, "utf8");
  let diagPromise = waitDiagnostics();
  notify("textDocument/didOpen", {
    textDocument: {
      uri: DOC_URI,
      languageId: "rza",
      version: 1,
      text: violText,
    },
  });
  let params = await diagPromise;
  check(
    "viol_i2: diagnostics не пусты",
    params.uri === DOC_URI && params.diagnostics.length > 0,
    JSON.stringify(params)
  );
  const i2 = (params.diagnostics || []).find((d) => d.code === "I2");
  check("viol_i2: есть диагностика [I2]", !!i2, JSON.stringify(params.diagnostics));
  check(
    "viol_i2: [I2] на строке 5 (0-based 4)",
    i2 && i2.range.start.line === 4,
    i2 && JSON.stringify(i2.range)
  );
  check(
    "viol_i2: severity=Error, source=rez3asm",
    i2 && i2.severity === 1 && i2.source === "rez3asm"
  );

  // 2. didChange с текстом fib.rza -> diagnostics пустой.
  const fibText = fs.readFileSync(FIB_FILE, "utf8");
  diagPromise = waitDiagnostics();
  notify("textDocument/didChange", {
    textDocument: { uri: DOC_URI, version: 2 },
    contentChanges: [{ text: fibText }],
  });
  params = await diagPromise;
  check(
    "fib: diagnostics пустой",
    params.uri === DOC_URI && params.diagnostics.length === 0,
    JSON.stringify(params.diagnostics)
  );

  // 3. shutdown + exit -> код 0.
  await request("shutdown");
  notify("exit");
  const code = await new Promise((resolve) => child.on("close", resolve));
  check("exit: сервер завершился с кодом 0", code === 0, `code=${code}`);

  if (serverStderr.trim()) {
    console.log(`--- server stderr ---\n${serverStderr.trim()}\n---`);
  }
  console.log(failures === 0 ? "SMOKE OK" : `SMOKE FAILED (${failures})`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(`smoke-test crashed: ${e.stack || e.message}`);
  child.kill();
  process.exit(1);
});
