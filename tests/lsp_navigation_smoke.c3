module rza_tests;

import std::collections::object;
import std::core::dstring;
import std::os::process;

char[1048576] navigation_source_buf;

fn String position_request(String method, int id, String uri, int line, int character) {
	DString out = dstring::temp(`{"jsonrpc":"2.0","id":`);
	out.appendf("%d", id);
	out.append_string(`,"method":`);
	json_string(&out, method);
	out.append_string(`,"params":{"textDocument":{"uri":`);
	json_string(&out, uri);
	out.append_string(`},"position":{"line":`);
	out.appendf("%d", line);
	out.append_string(`,"character":`);
	out.appendf("%d", character);
	out.append_string("}}}");
	return out.str_view();
}

fn Object*? position_call(
	Process* child,
	String method,
	int id,
	String uri,
	int line,
	int character
) {
	String request = position_request(method, id, uri, line, character);
	return lsp_call_json(child, request);
}

fn long object_int(Object* object, String key) {
	Object*? value = object.get(key);
	if (catch value) return -1;
	return value.is_int() ? (long)value.i : -1;
}

fn bool location_matches(Object* response, String uri, int line, int start, int end) {
	Object* result = response.get("result") ?? null;
	if (result == null || result.is_null()) return false;
	Object* actual_uri = result.get("uri") ?? null;
	if (actual_uri == null || !actual_uri.is_string() || actual_uri.s != uri) return false;
	Object* range = result.get("range") ?? null;
	if (range == null) return false;
	Object* start_pos = range.get("start") ?? null;
	Object* end_pos   = range.get("end") ?? null;
	if (start_pos == null || end_pos == null) return false;
	return object_int(
		start_pos,
		"line"
	) == line && object_int(
		start_pos,
		"character"
	) == start && object_int(end_pos, "line") == line && object_int(end_pos, "character") == end;
}

fn String hover_markdown(Object* response) {
	Object* result = response.get("result") ?? null;
	if (result == null || result.is_null()) return "";
	Object* contents = result.get("contents") ?? null;
	if (contents == null) return "";
	return contents.get_string("value") ?? "";
}

fn int? navigation_hover_definition_checks(Process* child) {
	char[] data      = read_file("examples/ring_buffer.rza", navigation_source_buf[..])!;
	Object* response = lsp_call_json(child, change_message((String)data, 2))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "navigation ring document")) {
		return 1;
	}
	response = position_call(child, "textDocument/hover", 90, GOOD_URI, 1, 8)!;
	String markdown = hover_markdown(response);
	if (!expect(markdown.contains("Ring") && markdown.contains("40"), "layout hover")) return 1;
	response = position_call(child, "textDocument/definition", 91, GOOD_URI, 3, 18)!;
	if (!expect(location_matches(response, GOOD_URI, 1, 7, 11), "layout definition")) return 1;
	response = position_call(child, "textDocument/definition", 92, GOOD_URI, 9, 28)!;
	if (!expect(location_matches(response, GOOD_URI, 1, 27, 32), "field definition")) return 1;
	response = position_call(child, "textDocument/hover", 93, GOOD_URI, 6, 5)!;
	markdown = hover_markdown(response);
	if (!expect(
		markdown.contains("Slot[4]") && markdown.contains("32"),
		"mediator hover"
	)) return 1;
	response = position_call(child, "textDocument/definition", 94, GOOD_URI, 56, 6)!;
	if (!expect(location_matches(response, GOOD_URI, 8, 5, 9), "procedure definition")) return 1;
	response = position_call(child, "textDocument/hover", 95, GOOD_URI, 7, 0)!;
	if (!expect(response.get("result")!.is_null(), "unknown hover")) return 1;
	response = position_call(child, "textDocument/hover", 96, GOOD_URI, 999, 0)!;
	if (!expect(response.get("result")!.is_null(), "position outside document")) return 1;
	return 0;
}

fn int? navigation_document_switch_checks(Process* child) {
	Object* response = lsp_call_json(child, open_message(BAD_URI, LAYOUT_TEXT, 3))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "second navigation document")) {
		return 1;
	}
	response = position_call(child, "textDocument/hover", 97, GOOD_URI, 1, 8)!;
	if (!expect(hover_markdown(response)
		.contains("Ring"), "first document model restored")) return 1;
	response = position_call(child, "textDocument/hover", 98, BAD_URI, 0, 8)!;
	if (!expect(hover_markdown(response).contains("Value"), "second document model")) return 1;
	return 0;
}

fn int? navigation_checks(Process* child) {
	if (navigation_hover_definition_checks(child)! != 0) return 1;
	if (navigation_document_switch_checks(child)! != 0) return 1;
	if (navigation_regression_checks(child)! != 0) return 1;
	return 0;
}

const String NAMESPACE_TEXT = "layout Entry: value:i64\n"
	"res entries, field, Entry[2]\n"
	"med worker_m, entries, field\n"
	"proc worker_m:\n"
	"    ret\n"
	"probe worker_m\n"
	"call worker_m\n"
	"ret\n";

const String KEYWORD_TEXT = "layout Entry: layout:i64\n"
	"res res, field, Entry[2]\n"
	"med res_m, res, field\n"
	"load %r0, [res_m + 0].layout\n"
	"print %r0\n"
	"ret\n";

const String SYNC_OUT_TEXT = "cav m, field\n"
	"res x, m, 8\n"
	"med x_m, x, m\n"
	"med before_m, ou\n"
	"casc c: x_m -> out[m]\n"
	"endc\n"
	"med after_m, ou\n"
	"decay m\n"
	"ret\n";

const String ASYNC_OUT_TEXT = "cav m, field\n"
	"res x, m, 8\n"
	"med x_m, x, m\n"
	"acasc c: x_m -> out\n"
	"endc\n"
	"await %r0\n"
	"decay m\n"
	"ret\n";

fn int? navigation_namespace_checks(Process* child) {
	Object* response = lsp_call_json(child, change_message(NAMESPACE_TEXT, 3))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "namespace document")) return 1;
	response = position_call(child, "textDocument/definition", 140, GOOD_URI, 5, 8)!;
	if (!expect(location_matches(response, GOOD_URI, 2, 4, 12), "mediator wins in probe")) return 1;
	response = position_call(child, "textDocument/definition", 141, GOOD_URI, 6, 6)!;
	if (!expect(location_matches(response, GOOD_URI, 3, 5, 13), "procedure wins in call")) return 1;
	response = lsp_call_json(child, change_message(KEYWORD_TEXT, 4))!;
	(void)response;
	response = position_call(child, "textDocument/definition", 142, GOOD_URI, 3, 24)!;
	if (!expect(
		location_matches(response, GOOD_URI, 0, 14, 20),
		"keyword field declaration"
	)) return 1;
	response = position_call(child, "textDocument/definition", 143, GOOD_URI, 2, 13)!;
	if (!expect(
		location_matches(response, GOOD_URI, 1, 4, 7),
		"keyword cell declaration"
	)) return 1;
	return 0;
}

fn int? navigation_cascade_out_checks(Process* child) {
	Object* response = lsp_call_json(child, change_message(SYNC_OUT_TEXT, 4))!;
	(void)response;
	response = position_call(child, "textDocument/definition", 144, GOOD_URI, 4, 16)!;
	if (!expect(
		location_matches(response, GOOD_URI, 4, 15, 18),
		"synchronous cascade output"
	)) return 1;
	response = position_call(child, "textDocument/completion", 145, GOOD_URI, 3, 16)!;
	if (!expect(
		completion_matches(response, { }, false),
		"cascade output before declaration"
	)) return 1;
	response = position_call(child, "textDocument/completion", 146, GOOD_URI, 6, 15)!;
	if (!expect(
		completion_matches(response, { "out" }, false),
		"cascade output after declaration"
	)) return 1;
	response = lsp_call_json(child, change_message(ASYNC_OUT_TEXT, 5))!;
	(void)response;
	response = position_call(child, "textDocument/definition", 147, GOOD_URI, 3, 17)!;
	if (!expect(
		location_matches(response, GOOD_URI, 3, 16, 19),
		"asynchronous cascade output"
	)) return 1;
	return 0;
}

fn int? navigation_regression_checks(Process* child) {
	if (navigation_namespace_checks(child)! != 0) return 1;
	if (navigation_cascade_out_checks(child)! != 0) return 1;
	return 0;
}
