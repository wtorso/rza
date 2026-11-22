module rza_tests;

import std::collections::object;
import std::core::dstring;
import std::io;
import std::io::path;
import std::os::process;
import std::thread;

const String BAD_URI          = "file:///smoke-bad.rza";
const String GOOD_URI         = "file:///smoke-good.rza";
const String BAD_TEXT         = "cav a\n";
const String GOOD_TEXT        = "cav m, field\ndecay m\nret\n";
const String CASCADE_TEXT     = "cav m, field\nres x, m, 8\nmed x_m, x, m\n"
	"casc c: x_m -> out[m]\n load %r0, [x_m + 0]\nendc\ndecay m\nret\n";
const String LAYOUT_TEXT      = "layout Value: value:i64\nres x, field, Value[2]\n"
	"med x_m, x, field\nmov %r0, 7\nmov %r1, 1\n"
	"store [x_m + %r1].value, %r0\nload %r0, [x_m + 0].value\nprint %r0\nret\n";
const String LAYOUT_BAD_TEXT  = "layout Value: value:i64\nres x, field, Value[2]\n"
	"med x_m, x, field\nmov %r0, 7\nmov %r1, 1\n"
	"store [x_m + %r1].value, %r0\nload %r0, [x_m + 0].missing\nprint %r0\nret\n";
const ulong MEMORY_GROWTH_MAX = 512 * 1024;

fn void json_string(DString* out, String text) {
	out.append_char('"');
	for (sz i = 0; i < text.len; i++) {
		char c = text[i];
		if (c == '"') {
			out.append(`\"`);
		} else if (c == '\\') {
			out.append(`\\`);
		} else if (c == '\n') {
			out.append(`\n`);
		} else if (c == '\r') {
			out.append(`\r`);
		} else if (c == '\t') {
			out.append(`\t`);
		} else {
			out.append_char(c);
		}
	}
	out.append_char('"');
}

fn String open_message(String uri, String text, int version) {
	DString out = dstring::temp(`{"jsonrpc":"2.0","method":"textDocument/didOpen",`);
	out.append(`"params":{"textDocument":{"uri":`);
	json_string(&out, uri);
	out.append(`,"languageId":"rza","version":`);
	out.appendf("%d", version);
	out.append(`,"text":`);
	json_string(&out, text);
	out.append(`}}}`);
	return out.str_view();
}

fn String change_message(String text, int version) {
	DString out = dstring::temp(`{"jsonrpc":"2.0","method":"textDocument/didChange",`);
	out.append(`"params":{"textDocument":{"uri":"file:///smoke-good.rza","version":`);
	out.appendf("%d", version);
	out.append(`},"contentChanges":[{"text":`);
	json_string(&out, text);
	out.append(`}]}}`);
	return out.str_view();
}

fn String? lsp_call(Process* child, String body) {
	lsp_send(child, lsp_frame(body))!;
	return lsp_recv(child)!;
}

fn Object*? lsp_call_json(Process* child, String body) {
	return json_message(lsp_call(child, body)!);
}

fn int? initialize_checks(Process* child) {
	Object* response = lsp_call_json(child, initialize("1"))!;
	if (!expect(json_id_int(response, 1), "initialize id")) return 1;
	Object* result       = response.get("result")!;
	Object* capabilities = result.get("capabilities")!;
	Object* sync         = capabilities.get("textDocumentSync")!;
	if (!expect(sync.is_int() && sync.i == 1, "initialize Full sync")) return 1;
	Object*? hover = capabilities.get("hoverProvider");
	if (catch hover) return 1;
	if (!expect(hover.is_bool() && hover.b, "initialize hover")) return 1;
	Object*? definition = capabilities.get("definitionProvider");
	if (catch definition) return 1;
	if (!expect(definition.is_bool() && definition.b, "initialize definition")) return 1;
	Object* references = capabilities.get("referencesProvider") ?? null;
	if (!expect(
		references != null && references.is_bool() && references.b,
		"initialize references"
	)) return 1;
	Object* rename_options = capabilities.get("renameProvider") ?? null;
	Object* prepare        = rename_options == null ? null
		: rename_options.get("prepareProvider") ?? null;
	if (!expect(prepare != null && prepare.is_bool() && prepare.b, "initialize prepare rename")) {
		return 1;
	}
	Object*? completion = capabilities.get("completionProvider");
	if (catch completion) return 1;
	Object*? resolve = completion.get("resolveProvider");
	if (catch resolve) return 1;
	if (!expect(resolve.is_bool() && !resolve.b, "completion resolve")) return 1;
	Object*? triggers = completion.get("triggerCharacters");
	if (catch triggers) return 1;
	if (!expect(
		triggers.get_len() == 1 && triggers.get_at(0).s == ".",
		"completion trigger"
	)) return 1;
	Object* info = result.get("serverInfo")!;
	if (!expect(
		(info.get_string(
			"name"
		) ?? "") == "rez3-lsp" && (info.get_string("version") ?? "") == "0.3.0",
		"initialize serverInfo"
	)) {
		return 1;
	}
	DString long_id = dstring::temp();
	for (int i = 0; i < 300; i++) long_id.append("x");
	response = lsp_call_json(child, initialize(string::tformat(`"%s"`, long_id.str_view())))!;
	if (!expect(
		json_id_null(response) && json_error_code(response, -32600),
		"oversized id"
	)) return 1;
	response = lsp_call_json(child, initialize("1.5"))!;
	if (!expect(json_id_number(response, 1.5), "fractional id")) return 1;
	return 0;
}

fn int? id_protocol_checks(Process* child) {
	String raw = lsp_call(child, initialize("1.2345678901234567"))!;
	if (!expect(
		raw.contains(
			`"id":1.2345678901234567`
		) && json_id_number(json_message(raw)!, 1.2345678901234567),
		"high precision id"
	)) return 1;
	raw = lsp_call(child, initialize("1.25e+20"))!;
	if (!expect(
		raw.contains(`"id":1.25e+20`) && json_id_number(json_message(raw)!, 1.25e20),
		"exponent id"
	)) return 1;
	Object* response = lsp_call_json(child, initialize("true"))!;
	if (!expect(
		json_id_null(response) && json_error_code(response, -32600),
		"boolean id"
	)) return 1;
	String payload = lsp_frame(initialize(`"fragmented"`));
	lsp_send(child, payload[:payload.len / 2])!;
	thread::sleep_ms(20)!;
	lsp_send(child, payload[payload.len / 2..])!;
	response = json_message(lsp_recv(child)!)!;
	Object* id = response.get("id")!;
	if (!expect(id.is_string() && id.s == "fragmented", "fragmented request")) return 1;
	return 0;
}

fn int? document_open_checks(Process* child) {
	Object* response = lsp_call_json(child, open_message(BAD_URI, BAD_TEXT, 1))!;
	Object* params   = response.get("params")!;
	if (!expect(
		(params.get_string("uri") ?? "") == BAD_URI && json_diagnostics(response)!.len() == 1,
		"bad document count"
	)) return 1;
	Object* diagnostic = json_diagnostics(response)!.get_at(0);
	Object* range      = diagnostic.get("range")!;
	Object* start      = range.get("start")!;
	Object* line       = start.get("line")!;
	if (!expect(
		(diagnostic.get_string(
			"code"
		) ?? "") == "STRUCT" && line.is_int() && line.i == 0 && (diagnostic.get_string(
			"source"
		) ?? "") == "rez3asm" && diagnostic.get("severity")!.i == 1,
		"bad document diagnostic"
	)) return 1;
	response = lsp_call_json(child, open_message(GOOD_URI, GOOD_TEXT, 1))!;
	params = response.get("params")!;
	if (!expect(
		(params.get_string("uri") ?? "") == GOOD_URI && json_diagnostics(response)!.len() == 0,
		"good document"
	)) return 1;
	return 0;
}

fn int? layout_document_checks(Process* child) {
	Object* response = lsp_call_json(child, change_message(LAYOUT_TEXT, 2))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "valid layout document")) {
		return 1;
	}
	response = lsp_call_json(child, change_message(LAYOUT_BAD_TEXT, 2))!;
	Object* diagnostics = json_diagnostics(response)!;
	if (!expect(diagnostics.len() == 1, "layout diagnostic count")) return 1;
	Object* diagnostic = diagnostics.get_at(0);
	Object* start      = diagnostic.get("range")!.get("start")!;
	Object* line       = start.get("line")!;
	String message     = diagnostic.get_string("message") ?? "";
	if (!expect(
		(diagnostic.get_string(
			"code"
		) ?? "") == "STRUCT" && line.is_int() && line.i
			== 6 && message == "unknown layout field missing",
		"layout field diagnostic"
	)) return 1;
	response = lsp_call_json(child, change_message(LAYOUT_TEXT, 2))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "layout diagnostic reset")) {
		return 1;
	}
	return 0;
}

fn int? churn(Process* child, int count) {
	for (int i = 0; i < count; i++) {
		String text      = i % 2 == 0 ? LAYOUT_TEXT : CASCADE_TEXT;
		Object* response = lsp_call_json(child, change_message(text, 2))!;
		Object* params   = response.get("params")!;
		if (!expect(
			(params.get_string("uri") ?? "") == GOOD_URI,
			"memory churn response"
		)) return 1;
		if (i % 32 == 0 && navigation_churn_requests(child, i)! != 0) return 1;
	}
	return 0;
}

fn int? memory_checks(Process* child) {
	if (layout_document_checks(child)! != 0) return 1;
	if (churn(child, 32)! != 0) return 1;
	ulong before = process_memory_bytes(child)!;
	if (churn(child, 2000)! != 0) return 1;
	ulong after  = process_memory_bytes(child)!;
	ulong growth = after > before ? after - before : 0;
	io::printfn("MEMORY before=%d, after=%d, growth=%d", before, after, growth);
	if (!expect(growth <= MEMORY_GROWTH_MAX, "memory growth over 512 KiB")) return 1;
	return 0;
}

fn int? malformed_change_checks(Process* child) {
	String[] changes = { "[]", "[{}]", "[null]", "[1]", "[[]]" };
	for (sz i = 0; i < changes.len; i++) {
		String body = string::tformat(
			`{"jsonrpc":"2.0","method":"textDocument/didChange","params":{`
				`"textDocument":{"uri":"file:///smoke-good.rza","version":2},`
				`"contentChanges":%s}}`,
			changes[i]
		);
		lsp_send(child, lsp_frame(body))!;
	}
	String[] malformed = {
		"null",
		"[]",
		`{"jsonrpc":"2.0","method":"textDocument/didOpen","params":null}`,
		`{"jsonrpc":"2.0","method":"textDocument/didChange","params":null}`,
		`{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":null}}`,
		`{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":[]}}`,
	};
	for (sz i = 0; i < malformed.len; i++) lsp_send(child, lsp_frame(malformed[i]))!;
	String missing      = "cav m, field\nres x, m, 8\nmed x_m, x, m\n"
		+++ "casc c: x_m -> out\nendc\nret\n";
	Object* response    = lsp_call_json(child, change_message(missing, 2))!;
	Object* diagnostics = json_diagnostics(response)!;
	bool valid          = diagnostics.len() == 2;
	for (sz i = 0; i < diagnostics.len(); i++) {
		if ((diagnostics.get_at(i).get_string("code") ?? "") != "STRUCT") valid = false;
	}
	if (!expect(valid, "malformed cascade diagnostics")) return 1;
	response = lsp_call_json(child, change_message(BAD_TEXT, 2))!;
	if (!expect(json_diagnostics(response)!.len() == 1, "change after churn")) return 1;
	return 0;
}

fn int? close_reopen_checks(Process* child) {
	String close = `{"jsonrpc":"2.0","method":"textDocument/didClose",`
		`"params":{"textDocument":{"uri":"file:///smoke-good.rza"}}}`;
	Object* response = lsp_call_json(child, close)!;
	Object* params   = response.get("params")!;
	if (!expect(
		(params.get_string("uri") ?? "") == GOOD_URI && json_diagnostics(response)!.len() == 0,
		"close diagnostics"
	)) return 1;
	response = lsp_call_json(child, open_message(GOOD_URI, GOOD_TEXT, 3))!;
	params = response.get("params")!;
	if (!expect(
		(params.get_string("uri") ?? "") == GOOD_URI && json_diagnostics(response)!.len() == 0,
		"reopen diagnostics"
	)) return 1;
	return 0;
}

fn int? diagnostic_limit_checks(Process* child) {
	DString many = dstring::temp();
	for (int i = 0; i < 1002; i++) many.append("x\n");
	Object* response    = lsp_call_json(child, change_message(many.str_view(), 4))!;
	Object* diagnostics = json_diagnostics(response)!;
	bool summary        = diagnostics.len() == 1001;
	if (summary) {
		Object* last = diagnostics.get_at(diagnostics.len() - 1);
		summary = (last.get_string("message") ?? "") == "2 diagnostics suppressed";
	}
	if (!expect(summary, "diagnostic summary")) return 1;
	response = lsp_call_json(child, change_message(GOOD_TEXT, 5))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "summary reset")) return 1;
	DString unicode = dstring::temp();
	for (int i = 0; i < 200; i++) unicode.append("€");
	unicode.append("\n");
	response = lsp_call_json(child, change_message(unicode.str_view(), 6))!;
	diagnostics = json_diagnostics(response)!;
	if (!expect(diagnostics.len() == 1, "UTF-8 diagnostic missing")) return 1;
	String message = diagnostics.get_at(0).get_string("message") ?? "";
	if (!expect(message.len <= 256 && !message.ends_with("�"), "UTF-8 diagnostic clip")) return 1;
	return 0;
}

fn int? shutdown_checks(Process* child) {
	Object* response = lsp_call_json(child, `{"jsonrpc":"2.0","id":2,"method":"shutdown"}`)!;
	Object* result   = response.get("result")!;
	if (!expect(
		json_id_int(response, 2) && result.is_null() && !response.has_key("error"),
		"shutdown response"
	)) return 1;
	lsp_send(child, lsp_frame(`{"jsonrpc":"2.0","method":"exit"}`))!;
	int status = wait_process(child)!;
	if (!expect(status == 0, "LSP exit status")) return 1;
	String stderr = read_child_stderr(child)!;
	if (stderr.len > 0) io::eprintfn("server stderr:\n%s", stderr);
	return 0;
}

fn int? run_oversize(String name, String payload, String expected) {
	ProcessResult result = run_simple_input({ compiler_path(), "--lsp" }, payload)!;
	if (!expect(result.status == 2 && result.stderr_text.contains(expected), name)) {
		print_result(result);
		return 1;
	}
	return 0;
}

fn int? oversize_static_checks() {
	DString header = dstring::temp();
	header.append_char_repeat('X', 9000);
	if (run_oversize("oversize header", header.str_view(), "header too large")! != 0) {
		return 1;
	}
	DString json = dstring::temp("[");
	for (int i = 0; i < 65537; i++) json.append("0,");
	json.append("0]");
	if (run_oversize(
		"oversize JSON values",
		lsp_frame(json.str_view()),
		"JSON values exceeds static budget"
	)! != 0) return 1;
	if (run_oversize(
		"oversize body",
		"Content-Length: 16777217\r\n\r\n",
		"body too large"
	)! != 0) return 1;
	return 0;
}

fn int? oversize_document_checks() {
	DString document = dstring::temp();
	document.append_char_repeat(';', 1048577);
	if (run_oversize(
		"oversize document",
		lsp_frame(open_message("file:///too-large.rza", document.str_view(), 1)),
		"document exceeds static budget"
	)! != 0) return 1;
	DString uri = dstring::temp("file:///");
	uri.append_char_repeat('u', 1024);
	if (run_oversize(
		"oversize URI",
		lsp_frame(open_message(uri.str_view(), "ret\n", 1)),
		"URI exceeds static budget"
	)! != 0) return 1;
	DString slots = dstring::temp();
	for (int i = 0; i < 65; i++) {
		slots.append(
			lsp_frame(open_message(string::tformat("file:///slot-%d.rza", i), "ret\n", 1))
		);
	}
	if (run_oversize(
		"oversize slots",
		slots.str_view(),
		"document slots exceeds static budget"
	)! != 0) return 1;
	return 0;
}

fn int lsp_main() {
	defer (void)cleanup_temp_dir();
	int? status = lsp_run();
	if (catch status) {
		io::eprintn("SMOKE FAILED");
		return 1;
	}
	return status;
}

fn int? lsp_run() {
	reset_temp_dir()!;
	Process child = lsp_start()!;
	defer lsp_destroy(&child);
	if (initialize_checks(&child)! != 0) return 1;
	if (id_protocol_checks(&child)! != 0) return 1;
	lsp_send(&child, lsp_frame(`{"jsonrpc":"2.0","method":"initialized","params":{}}`))!;
	if (document_open_checks(&child)! != 0) return 1;
	if (navigation_checks(&child)! != 0) return 1;
	if (completion_checks(&child)! != 0) return 1;
	if (references_checks(&child)! != 0) return 1;
	if (memory_checks(&child)! != 0) return 1;
	if (malformed_change_checks(&child)! != 0) return 1;
	if (close_reopen_checks(&child)! != 0) return 1;
	if (diagnostic_limit_checks(&child)! != 0) return 1;
	if (shutdown_checks(&child)! != 0) return 1;
	if (oversize_static_checks()! != 0) return 1;
	if (oversize_document_checks()! != 0) return 1;
	io::printn("SMOKE OK");
	return 0;
}
