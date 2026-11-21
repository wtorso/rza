module rza_tests;

import std::collections::object;
import std::core::dstring;
import std::os::process;
import std::io;

const sz TEST_LSP_RESPONSE_MAX = 4194304;

const String COMPLETION_TEXT = "layout Ring: read_pos:i64, count:i64, "
	+++ "input:i64, output:i64, status:i64\n"
	"layout Slot: value:i64\n"
	"res ring, field, Ring\n"
	"res slots, field, Slot[4]\n"
	"med ring_m, ring, field\n"
	"med slots_m, slots, field\n"
	"proc push:\n"
	"    call p\n"
	"    ret\n"
	"proc pop:\n"
	"    ret\n"
	"call pu\n"
	"res other, f\n"
	"res values, field, R\n"
	"med other_m, sl\n"
	"med second_m, slots, f\n"
	"probe ring\n"
	"store [ring_m + 0].c, %r0\n"
	"load %r0, [ring\n"
	"decay f\n"
	"call p\n"
	"store [ring\n"
	"storeb [ring\n"
	"store %r0, ring\n"
	"loadb %r0, [ring\n"
	"load.u32 %r0, [ring\n"
	"store.i64 [ring\n"
	"ret\n";

const String COMPLETION_TYPE_TEXT = "layout Pair: tag:u8, value:i64, signed:i8, "
	"half:u16, signed_half:i16, word:i32, tail:u32\n"
	"res pair, field, Pair\n"
	"med pair_m, pair, field\n"
	"load %r0, [pair_m + 0].\n"
	"load.i8 %r0, [pair\n"
	"load.u32 %r0, [pair\n"
	"store.i8 [pair\n"
	"store.i64 [pair\n"
	"load.u16 %r0, [pair\n"
	"store.u16 [pair\n"
	"load.i64 %r0, [pair\n"
	"ret\n";

fn bool completion_matches(Object* response, String[] expected, bool incomplete) {
	Object* result = response.get("result") ?? null;
	if (result == null || result.is_null()) return false;
	Object* items   = result.get("items") ?? null;
	Object* partial = result.get("isIncomplete") ?? null;
	if (items == null || partial == null || !items.is_indexable()) return false;
	if (!partial.is_bool() || partial.b != incomplete) return false;
	if (items.get_len() != expected.len) return false;
	foreach (want : expected) {
		bool found = false;
		for (sz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			if ((item.get_string("label") ?? "") == want) {
				found = true;
				break;
			}
		}
		if (!found) return false;
	}
	return true;
}

fn int? expect_completion(
	Process* child,
	int id,
	int line,
	int character,
	String[] expected,
	bool incomplete
) {
	Object* response = position_call(
		child,
		"textDocument/completion",
		id,
		GOOD_URI,
		line,
		character
	)!;
	if (!expect(completion_matches(response, expected, incomplete), "completion mismatch")) {
		io::eprintfn("completion id=%d response=%s", id, response);
		return 1;
	}
	return 0;
}

fn int? completion_name_checks(Process* child) {
	Object* response = lsp_call_json(child, change_message(COMPLETION_TEXT, 2))!;
	(void)response;
	if (expect_completion(child, 110, 11, 7, { "push" }, false)! != 0) return 1;
	if (expect_completion(child, 111, 12, 12, { "field" }, false)! != 0) return 1;
	if (expect_completion(child, 112, 13, 20, { "Ring" }, false)! != 0) return 1;
	if (expect_completion(child, 113, 14, 15, { "slots" }, false)! != 0) return 1;
	if (expect_completion(child, 114, 15, 22, { "field" }, false)! != 0) return 1;
	if (expect_completion(child, 115, 16, 10, { "ring_m" }, false)! != 0) return 1;
	if (expect_completion(child, 116, 17, 20, { "count" }, false)! != 0) return 1;
	if (expect_completion(child, 117, 18, 15, { "ring_m" }, false)! != 0) return 1;
	if (expect_completion(child, 118, 19, 7, { }, false)! != 0) return 1;
	if (expect_completion(child, 119, 20, 6, { "push", "pop" }, false)! != 0) return 1;
	return 0;
}

fn int? completion_scope_checks(Process* child) {
	if (expect_completion(child, 120, 0, 0, { }, false)! != 0) return 1;
	if (expect_completion(child, 121, 7, 9, { }, false)! != 0) return 1;
	Object* response = position_call(child, "textDocument/completion", 122, GOOD_URI, 999, 0)!;
	if (!expect(completion_matches(response, { }, false), "completion outside document")) return 1;
	return 0;
}

fn int? completion_limit_checks(Process* child) {
	DString text = dstring::temp();
	for (int i = 0; i < 300; i++) text.appendf("proc p%d:\nret\n", i);
	text.append_string("call p\nret\n");
	Object* response = lsp_call_json(child, change_message(text.str_view(), 3))!;
	(void)response;
	String request = position_request("textDocument/completion", 130, GOOD_URI, 600, 6);
	String raw     = lsp_call(child, request)!;
	if (!expect(raw.len <= TEST_LSP_RESPONSE_MAX, "completion response budget")) return 1;
	Object* message = json_message(raw)!;
	Object* result  = message.get("result")!;
	Object* items   = result.get("items")!;
	Object* partial = result.get("isIncomplete")!;
	if (!expect(
		items.get_len() == 256 && partial.is_bool() && partial.b,
		"completion cap and incomplete flag"
	)) return 1;
	return 0;
}

fn int? completion_view_checks(Process* child) {
	Object* response = lsp_call_json(child, change_message(VIEW_REF_TEXT, 40))!;
	(void)response;
	DString text = dstring::temp("res raw, field, 16\nmed raw_m, raw, field\n"
		"view raw_v_m, raw_m, 0, 8\nview nested_m, ra\nret\n");
	response = lsp_call_json(child, change_message(text.str_view(), 41))!;
	(void)response;
	return expect_completion(child, 130, 3, 17, { "raw_m", "raw_v_m" }, false);
}

fn int? completion_checks(Process* child) {
	if (completion_name_checks(child)! != 0) return 1;
	if (completion_scope_checks(child)! != 0) return 1;
	if (completion_limit_checks(child)! != 0) return 1;
	if (completion_regression_checks(child)! != 0) return 1;
	if (completion_type_detail_checks(child)! != 0) return 1;
	if (completion_view_checks(child)! != 0) return 1;
	return 0;
}

fn int? navigation_churn_requests(Process* child, int iteration) {
	Object* response = position_call(
		child,
		"textDocument/hover",
		10000 + iteration,
		GOOD_URI,
		1,
		8
	)!;
	(void)response;
	response = position_call(child, "textDocument/completion", 20000 + iteration, GOOD_URI, 1, 8)!;
	(void)response;
	return 0;
}

const String FIELD_SCOPE_TEXT = "layout Entry: value:i64\n"
	"proc first:\n"
	"    cav local, first\n"
	"    res entries, local, Entry\n"
	"    med entries_m, entries, local\n"
	"    ret\n"
	"proc second:\n"
	"    load %r0, [entries_m + 0].v\n"
	"    ret\n"
	"call first\n";

const String FORWARD_FIELD_TEXT = "layout Entry: value:i64\n"
	"res entries, field, Entry[2]\n"
	"load %r0, [entries_m + 0].v\n"
	"med entries_m, entries, field\n"
	"ret\n";

fn int? completion_store_checks(Process* child) {
	Object* response = lsp_call_json(child, change_message(COMPLETION_TEXT, 4))!;
	(void)response;
	if (expect_completion(child, 123, 21, 11, { "ring_m" }, false)! != 0) return 1;
	if (expect_completion(child, 124, 22, 12, { "ring_m" }, false)! != 0) return 1;
	if (expect_completion(child, 125, 23, 15, { }, false)! != 0) return 1;
	return 0;
}

fn int? completion_numeric_context_checks(Process* child) {
	Object* response = lsp_call_json(child, change_message(COMPLETION_TEXT, 5))!;
	(void)response;
	if (expect_completion(child, 128, 24, 16, { "ring_m" }, false)! != 0) return 1;
	if (expect_completion(child, 129, 25, 19, { "ring_m" }, false)! != 0) return 1;
	if (expect_completion(child, 131, 26, 15, { }, false)! != 0) return 1;
	return 0;
}

fn int? completion_field_scope_checks(Process* child) {
	Object* response = lsp_call_json(child, change_message(FIELD_SCOPE_TEXT, 3))!;
	(void)response;
	if (expect_completion(child, 126, 6, 31, { }, false)! != 0) return 1;
	response = lsp_call_json(child, change_message(FORWARD_FIELD_TEXT, 4))!;
	(void)response;
	if (expect_completion(child, 127, 2, 31, { }, false)! != 0) return 1;
	return 0;
}

fn int? completion_regression_checks(Process* child) {
	if (completion_store_checks(child)! != 0) return 1;
	if (completion_numeric_context_checks(child)! != 0) return 1;
	if (completion_field_scope_checks(child)! != 0) return 1;
	return 0;
}

fn bool completion_detail_matches(Object* response, String label, String detail) {
	Object* result = response.get("result") ?? null;
	if (result == null) return false;
	Object* items = result.get("items") ?? null;
	if (items == null || !items.is_indexable()) return false;
	for (sz i = 0; i < items.get_len(); i++) {
		Object* item = items.get_at(i);
		if ((item.get_string("label") ?? "") != label) continue;
		return (item.get_string("detail") ?? "") == detail;
	}
	return false;
}

fn int? completion_type_detail_checks(Process* child) {
	Object* diagnostics = lsp_call_json(child, change_message(COMPLETION_TYPE_TEXT, 6))!;
	if (!expect(json_diagnostics(diagnostics)!.len() > 0,
			"field completion document is intentionally invalid")) return 1;
	Object* response = position_call(child, "textDocument/completion", 132, GOOD_URI, 3, 23)!;
	if (!expect(completion_matches(response,
			{ "tag", "value", "signed", "half", "signed_half", "word", "tail" }, false),
			"field completion labels")) return 1;
	if (!expect(completion_detail_matches(response, "tag", "u8 field"),
			"u8 completion detail")) return 1;
	if (!expect(completion_detail_matches(response, "value", "i64 field"),
			"i64 completion detail")) return 1;
	if (!expect(completion_detail_matches(response, "signed", "i8 field"),
			"i8 completion detail")) return 1;
	if (!expect(completion_detail_matches(response, "half", "u16 field"),
			"u16 completion detail")) return 1;
	if (!expect(completion_detail_matches(response, "signed_half", "i16 field"),
			"i16 completion detail")) return 1;
	if (!expect(completion_detail_matches(response, "word", "i32 field"),
			"i32 completion detail")) return 1;
	if (!expect(completion_detail_matches(response, "tail", "u32 field"),
			"u32 completion detail")) return 1;
	if (expect_completion(child, 133, 4, 18, { "pair_m" }, false)! != 0) return 1;
	if (expect_completion(child, 134, 5, 18, { "pair_m" }, false)! != 0) return 1;
	if (expect_completion(child, 135, 6, 14, { "pair_m" }, false)! != 0) return 1;
	if (expect_completion(child, 136, 7, 15, { }, false)! != 0) return 1;
	if (expect_completion(child, 137, 8, 19, { "pair_m" }, false)! != 0) return 1;
	if (expect_completion(child, 138, 9, 15, { "pair_m" }, false)! != 0) return 1;
	if (expect_completion(child, 139, 10, 18, { }, false)! != 0) return 1;
	return 0;
}
