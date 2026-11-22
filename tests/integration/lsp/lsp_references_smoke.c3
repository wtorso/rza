module rza_tests;

import std::collections::object;
import std::core::dstring;
import std::io;
import std::os::process;

struct ExpectedLocation {
	int line;
	int start;
	int end;
}

const String REFERENCES_TEXT = "; 😀 read_first and value are comments\n"
	"layout Entry: value:i64, other:i64\n"
	"layout Other: value:i64\n"
	"cav local, field\n"
	"res first, local, Entry[2]\n"
	"res second, local, Entry\n"
	"res other, local, Other\n"
	"med first_m, first, local\n"
	"med second_m, second, local\n"
	"med other_m, other, local\n"
	"proc read_first:\n"
	"    load %r0, [first_m + 0].value\n"
	"    load %r1, [second_m + 0].value\n"
	"    load %r2, [other_m + 0].value\n"
	"    ret\n"
	"proc read_second:\n"
	"    call read_first\n"
	"    ret\n"
	"call read_second\n"
	"call read_first\n"
	"ret\n";

const String SYNC_REF_TEXT = "cav m, field\n"
	"res x, m, 8\n"
	"med x_m, x, m\n"
	"casc c: x_m -> out[m]\n"
	"endc\n"
	"med out_m, out, m\n"
	"probe out_m\n"
	"decay m\n"
	"ret\n";

const String ASYNC_REF_TEXT = "res x, field, 8\n"
	"med x_m, x, field\n"
	"acasc c: x_m -> out\n"
	"endc\n"
	"med out_m, out, field\n"
	"await %r0\n"
	"ret\n";

fn String reference_request(
	String method,
	int id,
	String uri,
	int line,
	int character,
	bool include_declaration
) {
	DString out = dstring::temp(`{"jsonrpc":"2.0","id":`);
	out.appendf("%d", id);
	out.append_string(`,"method":`);
	json_string(&out, method);
	out.append_string(`,"params":{"textDocument":{"uri":`);
	json_string(&out, uri);
	out.appendf(
		`},"position":{"line":%d,"character":%d},"context":{"includeDeclaration":%s}}}`,
		line,
		character,
		include_declaration ? "true" : "false"
	);
	return out.str_view();
}

fn Object*? reference_call(
	Process* child,
	int id,
	String uri,
	int line,
	int character,
	bool include_declaration
) {
	String request = reference_request(
		"textDocument/references",
		id,
		uri,
		line,
		character,
		include_declaration
	);
	return lsp_call_json(child, request);
}

fn bool reference_matches(Object* response, String uri, ExpectedLocation[] expected) {
	Object* result = response.get("result") ?? null;
	if (result == null || !result.is_indexable() || result.get_len() != expected.len) return false;
	foreach (want : expected) {
		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* location   = result.get_at(i);
			Object* actual_uri = location.get("uri") ?? null;
			Object* range      = location.get("range") ?? null;
			if (actual_uri == null || range == null || actual_uri.s != uri) continue;
			Object* start = range.get("start") ?? null;
			Object* end   = range.get("end") ?? null;
			if (start == null || end == null) continue;
			if (object_int(
				start,
				"line"
			) == want.line && object_int(
				start,
				"character"
			) == want.start && object_int(
				end,
				"line"
			) == want.line && object_int(end, "character") == want.end) {
				found = true;
				break;
			}
		}
		if (!found) return false;
	}
	return true;
}

fn int? expect_references(
	Process* child,
	int id,
	String uri,
	int line,
	int character,
	bool include_declaration,
	ExpectedLocation[] expected,
	String message
) {
	Object* response = reference_call(child, id, uri, line, character, include_declaration)!;
	if (!expect(reference_matches(response, uri, expected), message)) {
		io::eprintfn("references id=%d response=%s", id, response);
		return 1;
	}
	return 0;
}

fn int? set_reference_document(Process* child, String text, int version) {
	Object* response = lsp_call_json(child, change_message(text, version))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "reference document")) return 1;
	return 0;
}

fn int? reference_proc_field_checks(Process* child) {
	int status = 0;
	if (set_reference_document(child, REFERENCES_TEXT, 3)! != 0) return 1;
	if (expect_references(
		child,
		200,
		GOOD_URI,
		19,
		7,
		true,
		{ { 10, 5, 15 }, { 16, 9, 19 }, { 19, 5, 15 } },
		"procedure references with declaration"
	)! != 0) status = 1;
	if (expect_references(
		child,
		201,
		GOOD_URI,
		10,
		8,
		false,
		{ { 16, 9, 19 }, { 19, 5, 15 } },
		"declaration origin excludes declaration"
	)! != 0) status = 1;
	if (expect_references(
		child,
		202,
		GOOD_URI,
		11,
		30,
		true,
		{ { 1, 14, 19 }, { 11, 28, 33 }, { 12, 29, 34 } },
		"layout field shared by cells"
	)! != 0) status = 1;
	if (expect_references(
		child,
		203,
		GOOD_URI,
		13,
		30,
		true,
		{ { 2, 14, 19 }, { 13, 28, 33 } },
		"same field name in another layout"
	)! != 0) status = 1;
	return status;
}

fn int? reference_owner_checks(Process* child) {
	int status = 0;
	if (expect_references(
		child,
		204,
		GOOD_URI,
		4,
		20,
		true,
		{ { 1, 7, 12 }, { 4, 18, 23 }, { 5, 19, 24 } },
		"layout references"
	)! != 0) status = 1;
	if (expect_references(
		child,
		205,
		GOOD_URI,
		3,
		6,
		true,
		{
			{ 3, 4, 9 },
			{ 4, 11, 16 },
			{ 5, 12, 17 },
			{ 6, 11, 16 },
			{ 7, 20, 25 },
			{ 8, 22, 27 },
			{ 9, 20, 25 }
		},
		"frame references"
	)! != 0) status = 1;
	if (expect_references(
		child,
		206,
		GOOD_URI,
		4,
		6,
		true,
		{ { 4, 4, 9 }, { 7, 13, 18 } },
		"cell references"
	)! != 0) status = 1;
	if (expect_references(
		child,
		207,
		GOOD_URI,
		7,
		6,
		true,
		{ { 7, 4, 11 }, { 11, 15, 22 } },
		"mediator references"
	)! != 0) status = 1;
	return status;
}

fn int? reference_keyword_ab_checks(Process* child) {
	int status = 0;
	if (expect_references(
		child,
		208,
		GOOD_URI,
		19,
		7,
		true,
		{ { 10, 5, 15 }, { 16, 9, 19 }, { 19, 5, 15 } },
		"A document excludes B document"
	)! != 0) status = 1;
	Object* response = lsp_call_json(child, open_message(BAD_URI, REFERENCES_TEXT, 3))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "B reference document")) return 1;
	if (expect_references(
		child,
		209,
		GOOD_URI,
		19,
		7,
		true,
		{ { 10, 5, 15 }, { 16, 9, 19 }, { 19, 5, 15 } },
		"open B document remains isolated"
	)! != 0) status = 1;
	if (set_reference_document(child, KEYWORD_TEXT, 4)! != 0) return 1;
	if (expect_references(
		child,
		210,
		GOOD_URI,
		1,
		5,
		true,
		{ { 1, 4, 7 }, { 2, 11, 14 } },
		"keyword-like cell references"
	)! != 0) {
		status = 1;
	}
	if (expect_references(
		child,
		211,
		GOOD_URI,
		3,
		24,
		true,
		{ { 0, 14, 20 }, { 3, 22, 28 } },
		"keyword-like field references"
	)! != 0) {
		status = 1;
	}
	if (expect_references(
		child,
		212,
		GOOD_URI,
		999,
		0,
		true,
		{ },
		"references outside document"
	)! != 0) status = 1;
	return status;
}

fn int? reference_cascade_checks(Process* child) {
	int status = 0;
	if (set_reference_document(child, SYNC_REF_TEXT, 5)! != 0) return 1;
	if (expect_references(
		child,
		213,
		GOOD_URI,
		3,
		19,
		true,
		{ { 0, 4, 5 }, { 1, 7, 8 }, { 2, 12, 13 }, { 3, 19, 20 }, { 5, 16, 17 }, { 7, 6, 7 } },
		"synchronous output frame references"
	)! != 0) status = 1;
	if (expect_references(
		child,
		214,
		GOOD_URI,
		3,
		16,
		true,
		{ { 3, 15, 18 }, { 5, 11, 14 } },
		"synchronous output cell"
	)! != 0) {
		status = 1;
	}
	if (set_reference_document(child, ASYNC_REF_TEXT, 6)! != 0) return 1;
	if (expect_references(
		child,
		215,
		GOOD_URI,
		2,
		17,
		true,
		{ { 2, 16, 19 }, { 4, 11, 14 } },
		"asynchronous output cell"
	)! != 0) {
		status = 1;
	}
	return status;
}

const String VIEW_REF_TEXT = "res raw, field, 16\n"
    "med raw_m, raw, field\n"
    "view raw_v_m, raw_m, 0, 8\n"
    "view nested_m, raw_v_m, 1, 4\n"
    "probe nested_m\n"
    "ret\n";

fn int? reference_view_checks(Process* child) {
    if (set_reference_document(child, VIEW_REF_TEXT, 35)! != 0) return 1;
    if (expect_references(child, 520, GOOD_URI, 1, 5, true,
            { { 1, 4, 9 }, { 2, 14, 19 } }, "view source references")! != 0) return 1;
    if (expect_references(child, 521, GOOD_URI, 2, 6, true,
            { { 2, 5, 12 }, { 3, 15, 22 } }, "view declaration and nested use")! != 0) {
        return 1;
    }
    if (expect_references(child, 522, GOOD_URI, 4, 8, true,
            { { 3, 5, 13 }, { 4, 6, 14 } }, "nested view references")! != 0) return 1;
    Object* response = rename_call(child, 523, GOOD_URI, 2, 6, "slice_m")!;
    ExpectedLocation[] edits = { { 2, 5, 12 }, { 3, 15, 22 } };
    if (!expect(rename_edit_matches(response, GOOD_URI, 35, "slice_m", edits),
            "view rename edits")) return 1;
    String edited = apply_rename(VIEW_REF_TEXT, response)!;
    if (set_reference_document(child, edited, 36)! != 0) return 1;
    if (set_reference_document(child, VIEW_REF_TEXT, 37)! != 0) return 1;
    return expect_rename_error(child, 524, 1, 5, "raw_v_m", -32803,
        "view collision rejects versioned rename");
}

fn String many_calls(int count) {
	DString text = dstring::temp("proc p:\n    ret\n");
	for (int i = 0; i < count; i++) text.append_string("call p\n");
	text.append_string("ret\n");
	return text.str_view();
}

fn int? reference_limit_checks(Process* child) {
	int status = 0;
	if (set_reference_document(child, many_calls(4096), 7)! != 0) return 1;
	Object* response = reference_call(child, 216, GOOD_URI, 2, 6, true)!;
	if (!expect(json_error_code(response, -32803), "reference occurrence limit")) status = 1;
	DString text = dstring::temp(many_calls(4095));
	DString uri  = dstring::temp("file:///");
	while (uri.len() < 1024) uri.append_char('u');
	response = lsp_call_json(child, open_message(uri.str_view(), text.str_view(), 1))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "long URI document")) return 1;
	response = reference_call(child, 217, uri.str_view(), 2, 6, true)!;
	if (!expect(json_error_code(response, -32803), "reference response limit")) status = 1;
	return status;
}

fn String reference_string_id_request(sz id_len, String uri) {
	DString out = dstring::temp(`{"jsonrpc":"2.0","id":"`);
	for (sz i = 0; i < id_len; i++) out.append_char('i');
	out.append_string(`","method":"textDocument/references","params":{"textDocument":{"uri":`);
	json_string(&out, uri);
	out.append_string(
		`},"position":{"line":2,"character":6},"context":{"includeDeclaration":true}}}`
	);
	return out.str_view();
}

fn int? response_envelope_boundary_checks(Process* child) {
	DString uri = dstring::temp("file:///");
	while (uri.len() < 956) uri.append_char('u');
	Object* response = lsp_call_json(child, open_message(uri.str_view(), many_calls(4007), 1))!;
	if (!expect(json_diagnostics(response)!.len() == 0, "boundary document")) return 1;
	String raw = lsp_call(child, reference_string_id_request(1, uri.str_view()))!;
	if (!expect(raw.len <= TEST_LSP_RESPONSE_MAX, "boundary fixture fits")) return 1;
	response = json_message(raw)!;
	Object* result = response.get("result") ?? null;
	if (!expect(
		result != null && result.is_indexable() && result.get_len() == 4008,
		"boundary fixture references"
	)) return 1;
	sz padding = TEST_LSP_RESPONSE_MAX - raw.len;
	if (!expect(padding <= 254, "boundary fixture leaves adjustable ID space")) return 1;
	raw = lsp_call(child, reference_string_id_request(1 + padding, uri.str_view()))!;
	if (!expect(raw.len == TEST_LSP_RESPONSE_MAX, "response at exact budget")) {
		io::eprintfn("exact boundary bytes=%d", raw.len);
		return 1;
	}
	response = json_message(raw)!;
	result = response.get("result") ?? null;
	if (!expect(
		result != null && result.is_indexable() && result.get_len() == 4008,
		"exact boundary returns all references"
	)) return 1;
	raw = lsp_call(child, reference_string_id_request(2 + padding, uri.str_view()))!;
	response = json_message(raw)!;
	if (!expect(json_error_code(response, -32803), "response envelope above budget")) {
		io::eprintfn("oversize response bytes=%d", raw.len);
		return 1;
	}
	return 0;
}

fn int? references_checks(Process* child) {
	int status = 0;
	if (reference_proc_field_checks(child)! != 0) status = 1;
	if (reference_owner_checks(child)! != 0) status = 1;
	if (reference_keyword_ab_checks(child)! != 0) status = 1;
	if (reference_cascade_checks(child)! != 0) status = 1;
	if (reference_limit_checks(child)! != 0) status = 1;
	if (response_envelope_boundary_checks(child)! != 0) status = 1;
	if (reference_view_checks(child)! != 0) status = 1;
	if (rename_checks(child)! != 0) status = 1;
	return status;
}


fn Object*? rename_call(
	Process* child,
	int id,
	String uri,
	int line,
	int character,
	String new_name
) {
	DString out = dstring::temp(`{"jsonrpc":"2.0","id":`);
	out.appendf("%d", id);
	out.append_string(`,"method":"textDocument/rename","params":{"textDocument":{"uri":`);
	json_string(&out, uri);
	out.appendf(`},"position":{"line":%d,"character":%d},"newName":`, line, character);
	json_string(&out, new_name);
	out.append_string("}}");
	return lsp_call_json(child, out.str_view());
}

fn bool prepare_matches(Object* response, int line, int start, int end, String placeholder) {
	Object* result = response.get("result") ?? null;
	if (result == null || result.is_null()) return false;
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
	) == start && object_int(
		end_pos,
		"line"
	) == line && object_int(
		end_pos,
		"character"
	) == end && (result.get_string("placeholder") ?? "") == placeholder;
}

fn bool rename_edit_matches(
	Object* response,
	String uri,
	int version,
	String new_name,
	ExpectedLocation[] expected
) {
	Object* result  = response.get("result") ?? null;
	Object* changes = result == null ? null : result.get("documentChanges") ?? null;
	if (changes == null || !changes.is_indexable() || changes.get_len() != 1) return false;
	Object* change = changes.get_at(0);
	Object* td     = change.get("textDocument") ?? null;
	Object* edits  = change.get("edits") ?? null;
	if (td == null || edits == null || !edits.is_indexable()) return false;
	if ((td.get_string("uri") ?? "") != uri || object_int(td, "version") != version) {
		return false;
	}
	if (edits.get_len() != expected.len) return false;
	foreach (want : expected) {
		bool found = false;
		for (sz i = 0; i < edits.get_len(); i++) {
			Object* edit  = edits.get_at(i);
			Object* range = edit.get("range") ?? null;
			if (range == null || (edit.get_string("newText") ?? "") != new_name) continue;
			Object* start = range.get("start") ?? null;
			Object* end   = range.get("end") ?? null;
			if (start == null || end == null) continue;
			if (object_int(
				start,
				"line"
			) == want.line && object_int(
				start,
				"character"
			) == want.start && object_int(
				end,
				"line"
			) == want.line && object_int(end, "character") == want.end) {
				found = true;
				break;
			}
		}
		if (!found) return false;
	}
	return true;
}

fn int source_offset(String source, int target_line, int character) {
	if (target_line < 0 || character < 0) return -1;
	int line = 0;
	int pos  = 0;
	while (line < target_line) {
		sz? newline = source[pos..].index_of_char('\n');
		if (catch newline) return -1;
		pos += (int)newline + 1;
		line++;
	}
	int end = pos;
	while (end < (int)source.len && source[end] != '\n') end++;
	if (pos + character > end) return -1;
	return pos + character;
}

fn String? apply_rename(String source, Object* response) {
	Object* result  = response.get("result")!;
	Object* changes = result.get("documentChanges")!;
	if (changes.get_len() != 1) return TEST_ERROR~;
	Object* edits = changes.get_at(0).get("edits")!;
	DString out   = dstring::temp(source);
	for (sz i = edits.get_len(); i > 0; i--) {
		Object* edit  = edits.get_at(i - 1);
		Object* range = edit.get("range")!;
		Object* start = range.get("start")!;
		Object* end   = range.get("end")!;
		int from = source_offset(
			source,
			(int)object_int(start, "line"),
			(int)object_int(start, "character")
		);
		int to = source_offset(
			source,
			(int)object_int(end, "line"),
			(int)object_int(end, "character")
		);
		if (from < 0 || to < from) return TEST_ERROR~;
		String new_text = edit.get_string("newText")!;
		out.delete((sz)from, (sz)(to - from));
		out.insert_chars_at((sz)from, new_text);
	}
	return out.str_view();
}

fn int? expect_rename_error(
	Process* child,
	int id,
	int line,
	int character,
	String new_name,
	int code,
	String message
) {
	Object* response = rename_call(child, id, GOOD_URI, line, character, new_name)!;
	if (!expect(json_error_code(response, code), message)) {
		io::eprintfn("rename id=%d response=%s", id, response);
		return 1;
	}
	return 0;
}

fn int? expect_valid_rename(
	Process* child,
	int id,
	int line,
	int character,
	String new_name,
	ExpectedLocation[] expected,
	String message
) {
	if (set_reference_document(child, REFERENCES_TEXT, 12)! != 0) return 1;
	Object* response = rename_call(child, id, GOOD_URI, line, character, new_name)!;
	if (!expect(rename_edit_matches(response, GOOD_URI, 12, new_name, expected), message)) {
		io::eprintfn("rename id=%d response=%s", id, response);
		return 1;
	}
	String edited = apply_rename(REFERENCES_TEXT, response)!;
	if (!expect(edited.contains("😀 read_first and value"), "rename preserves comments")) {
		return 1;
	}
	if (set_reference_document(child, edited, 13)! != 0) return 1;
	Object* refs   = reference_call(child, id + 100, GOOD_URI, line, character, true)!;
	Object* result = refs.get("result") ?? null;
	if (!expect(
		result != null && result.is_indexable() && result.get_len() == expected.len,
		"references after rename"
	)) return 1;
	return 0;
}

fn int? rename_valid_checks(Process* child) {
	int status = 0;
	if (expect_valid_rename(
		child,
		300,
		19,
		7,
		"read_renamed",
		{ { 10, 5, 15 }, { 16, 9, 19 }, { 19, 5, 15 } },
		"procedure rename"
	)! != 0) status = 1;
	if (expect_valid_rename(
		child,
		301,
		11,
		30,
		"payload",
		{ { 1, 14, 19 }, { 11, 28, 33 }, { 12, 29, 34 } },
		"layout field rename"
	)! != 0) status = 1;
	if (expect_valid_rename(
		child,
		302,
		4,
		20,
		"Record",
		{ { 1, 7, 12 }, { 4, 18, 23 }, { 5, 19, 24 } },
		"layout rename"
	)! != 0) status = 1;
	if (expect_valid_rename(
		child,
		303,
		3,
		6,
		"scope",
		{
			{ 3, 4, 9 },
			{ 4, 11, 16 },
			{ 5, 12, 17 },
			{ 6, 11, 16 },
			{ 7, 20, 25 },
			{ 8, 22, 27 },
			{ 9, 20, 25 }
		},
		"frame rename"
	)! != 0) status = 1;
	if (expect_valid_rename(
		child,
		304,
		4,
		6,
		"primary",
		{ { 4, 4, 9 }, { 7, 13, 18 } },
		"cell rename"
	)! != 0) status = 1;
	if (expect_valid_rename(
		child,
		305,
		7,
		6,
		"primary_m",
		{ { 7, 4, 11 }, { 11, 15, 22 } },
		"mediator rename"
	)! != 0) status = 1;
	return status;
}

fn int? rename_prepare_checks(Process* child) {
	int status = 0;
	if (set_reference_document(child, REFERENCES_TEXT, 11)! != 0) return 1;
	Object* response = position_call(child, "textDocument/prepareRename", 310, GOOD_URI, 19, 7)!;
	if (!expect(
		prepare_matches(response, 19, 5, 15, "read_first"),
		"prepare procedure rename"
	)) status = 1;
	response = position_call(child, "textDocument/prepareRename", 311, GOOD_URI, 3, 12)!;
	Object* result = response.get("result") ?? null;
	if (!expect(result != null && result.is_null(), "prepare builtin is rejected")) status = 1;
	response = position_call(child, "textDocument/prepareRename", 312, GOOD_URI, 999, 0)!;
	result = response.get("result") ?? null;
	if (!expect(result != null && result.is_null(), "prepare outside document")) status = 1;
	return status;
}

const String RENAME_LABEL_TEXT = "proc p:\nagain:\n    jmp again\n    ret\n";

fn int? rename_invalid_checks(Process* child) {
	int status = 0;
	if (set_reference_document(child, REFERENCES_TEXT, 14)! != 0) return 1;
	if (expect_rename_error(
		child,
		320,
		19,
		7,
		"Bad",
		-32602,
		"invalid procedure name"
	)! != 0) status = 1;
	if (expect_rename_error(
		child,
		321,
		7,
		6,
		"renamed",
		-32602,
		"mediator suffix required"
	)! != 0) status = 1;
	if (expect_rename_error(
		child,
		322,
		4,
		20,
		"record",
		-32602,
		"layout case required"
	)! != 0) status = 1;
	if (expect_rename_error(
		child,
		323,
		19,
		7,
		"read_second",
		-32803,
		"procedure collision"
	)! != 0) status = 1;
	if (expect_rename_error(
		child,
		324,
		11,
		30,
		"other",
		-32803,
		"field collision"
	)! != 0) status = 1;
	if (expect_rename_error(
		child,
		325,
		3,
		12,
		"root",
		-32602,
		"builtin rename rejected"
	)! != 0) status = 1;
	return rename_invalid_source_checks(child);
}

fn int? rename_invalid_source_checks(Process* child) {
	int status = 0;
	if (set_reference_document(child, RENAME_LABEL_TEXT, 15)! != 0) return 1;
	if (expect_rename_error(
		child,
		326,
		1,
		2,
		"later",
		-32602,
		"label rename rejected"
	)! != 0) status = 1;
	Object* response = lsp_call_json(child, change_message(LAYOUT_BAD_TEXT, 16))!;
	(void)response;
	if (expect_rename_error(
		child,
		327,
		1,
		5,
		"y",
		-32803,
		"invalid original document"
	)! != 0) status = 1;
	if (set_reference_document(child, many_calls(4096), 17)! != 0) return 1;
	if (expect_rename_error(
		child,
		328,
		2,
		6,
		"q",
		-32803,
		"rename occurrence limit"
	)! != 0) status = 1;
	return status;
}

fn int? rename_oversize_checks(Process* child) {
	if (set_reference_document(child, "proc p:\n    ret\ncall p\nret\n", 18)! != 0) return 1;
	DString name = dstring::temp();
	for (int i = 0; i < 1048576; i++) name.append_char('p');
	return expect_rename_error(
		child,
		329,
		2,
		6,
		name.str_view(),
		-32803,
		"renamed document exceeds source budget"
	);
}

fn int? rename_churn_checks(Process* child) {
	if (set_reference_document(child, REFERENCES_TEXT, 19)! != 0) return 1;
	ulong before = process_memory_bytes(child)!;
	for (int i = 0; i < 64; i++) {
		Object* response = rename_call(child, 400 + i, GOOD_URI, 19, 7, "read_renamed")!;
		if (!expect(
			rename_edit_matches(
				response,
				GOOD_URI,
				19,
				"read_renamed",
				{ { 10, 5, 15 }, { 16, 9, 19 }, { 19, 5, 15 } }
			),
			"rename churn response"
		)) return 1;
	}
	ulong after  = process_memory_bytes(child)!;
	ulong growth = after > before ? after - before : 0;
	if (!expect(growth <= MEMORY_GROWTH_MAX, "rename memory growth")) return 1;
	return 0;
}

fn int? rename_checks(Process* child) {
	int status = 0;
	if (rename_valid_checks(child)! != 0) status = 1;
	if (rename_prepare_checks(child)! != 0) status = 1;
	if (rename_invalid_checks(child)! != 0) status = 1;
	if (rename_oversize_checks(child)! != 0) status = 1;
	if (rename_churn_checks(child)! != 0) status = 1;
	if (rename_review_regression_checks(child)! != 0) status = 1;
	return status;
}


const String CASCADE_COLLISION_TEXT = "res x, field, 8\n"
	"med x_m, x, field\n"
	"acasc x_m: x_m -> out\n"
	"endc\n"
	"probe x_m\n"
	"ret\n";

fn int? cascade_collision_checks(Process* child) {
	int status = 0;
	if (set_reference_document(child, CASCADE_COLLISION_TEXT, 30)! != 0) return 1;
	if (expect_references(
		child,
		500,
		GOOD_URI,
		4,
		7,
		true,
		{ { 1, 4, 7 }, { 2, 11, 14 }, { 4, 6, 9 } },
		"cascade name is not a mediator reference"
	)! != 0) status = 1;
	Object* response = position_call(child, "textDocument/prepareRename", 501, GOOD_URI, 2, 7)!;
	Object* result   = response.get("result") ?? null;
	if (!expect(result != null && result.is_null(), "cascade name prepare is rejected")) status = 1;
	response = rename_call(child, 502, GOOD_URI, 4, 7, "y_m")!;
	if (!expect(
		rename_edit_matches(
			response,
			GOOD_URI,
			30,
			"y_m",
			{ { 1, 4, 7 }, { 2, 11, 14 }, { 4, 6, 9 } }
		),
		"mediator rename preserves cascade name"
	)) {
		io::eprintfn("cascade collision response=%s", response);
		status = 1;
	}
	return status;
}

const String IMPLICIT_FRAME_TEXT = "proc work:\n"
	"    cav child, work\n"
	"    res x, child, 8\n"
	"    med x_m, x, child\n"
	"    ret\n"
	"call work\n"
	"ret\n";

fn int? implicit_frame_checks(Process* child) {
	int status = 0;
	if (set_reference_document(child, IMPLICIT_FRAME_TEXT, 31)! != 0) return 1;
	if (expect_references(
		child,
		503,
		GOOD_URI,
		1,
		16,
		true,
		{ { 0, 5, 9 }, { 1, 15, 19 } },
		"implicit frame includes procedure declaration"
	)! != 0) status = 1;
	if (expect_references(
		child,
		504,
		GOOD_URI,
		1,
		16,
		false,
		{ { 1, 15, 19 } },
		"implicit frame excludes shared declaration"
	)! != 0) {
		status = 1;
	}
	if (expect_references(
		child,
		505,
		GOOD_URI,
		5,
		6,
		true,
		{ { 0, 5, 9 }, { 1, 15, 19 }, { 5, 5, 9 } },
		"procedure references include implicit frame uses"
	)! != 0) status = 1;
	Object* response = rename_call(child, 506, GOOD_URI, 5, 6, "worker")!;
	if (!expect(
		rename_edit_matches(
			response,
			GOOD_URI,
			31,
			"worker",
			{ { 0, 5, 9 }, { 1, 15, 19 }, { 5, 5, 9 } }
		),
		"procedure rename includes implicit frame"
	)) {
		io::eprintfn("implicit frame response=%s", response);
		return 1;
	}
	String edited = apply_rename(IMPLICIT_FRAME_TEXT, response)!;
	if (set_reference_document(child, edited, 32)! != 0) return 1;
	return status;
}

fn int? empty_change_version_checks(Process* child) {
	if (set_reference_document(child, REFERENCES_TEXT, 33)! != 0) return 1;
	DString change = dstring::temp(`{"jsonrpc":"2.0","method":"textDocument/didChange",`);
	change.append_string(`"params":{"textDocument":{"uri":`);
	json_string(&change, GOOD_URI);
	change.append_string(`,"version":34},"contentChanges":[]}}`);
	lsp_send(child, lsp_frame(change.str_view()))!;
	Object* response = rename_call(child, 507, GOOD_URI, 19, 7, "read_renamed")!;
	if (!expect(
		rename_edit_matches(
			response,
			GOOD_URI,
			34,
			"read_renamed",
			{ { 10, 5, 15 }, { 16, 9, 19 }, { 19, 5, 15 } }
		),
		"empty change advances rename version"
	)) {
		io::eprintfn("empty change response=%s", response);
		return 1;
	}
	return 0;
}

fn int? rename_review_regression_checks(Process* child) {
	int status = 0;
	if (cascade_collision_checks(child)! != 0) status = 1;
	if (implicit_frame_checks(child)! != 0) status = 1;
	if (empty_change_version_checks(child)! != 0) status = 1;
	return status;
}
