;;; -*- lexical-binding: t; -*-

(require 'prog-mode)

(defconst rza-opcodes
  '("cav" "res" "med" "view" "raise" "decay" "probe" "load" "loadb"
    "mov" "store" "storeb" "slt" "inc" "dec" "await" "print"
    "jmp" "brz" "brnz" "call" "proc" "casc" "acasc" "endc" "ret"
    "layout" "add" "sub" "mul" "div" "mod" "and" "or" "xor"
    "shl" "shr" "ushr" "cadd" "csub" "cmul" "cinc" "cdec" "crc32c"))

(defconst rza-typed-opcode-bases
  '("mov" "load" "store" "add" "sub" "mul" "inc" "dec"
    "cadd" "csub" "cmul" "cinc" "cdec" "and" "or" "xor"
    "div" "mod" "shl" "ushr"))

(defconst rza-conversion-opcodes
  '("cvt.f32.f64" "cvt.f64.f32"
    "cvt.f32.i8" "cvt.f32.u8" "cvt.f32.i16" "cvt.f32.u16"
    "cvt.f32.i32" "cvt.f32.u32" "cvt.f32.i64" "cvt.f32.u64"
    "cvt.f64.i8" "cvt.f64.u8" "cvt.f64.i16" "cvt.f64.u16"
    "cvt.f64.i32" "cvt.f64.u32" "cvt.f64.i64" "cvt.f64.u64"
    "cvt.i8.f32" "cvt.u8.f32" "cvt.i16.f32" "cvt.u16.f32"
    "cvt.i32.f32" "cvt.u32.f32" "cvt.i64.f32" "cvt.u64.f32"
    "cvt.i8.f64" "cvt.u8.f64" "cvt.i16.f64" "cvt.u16.f64"
    "cvt.i32.f64" "cvt.u32.f64" "cvt.i64.f64" "cvt.u64.f64"
    "bitcast.f32.i32" "bitcast.f32.u32"
    "bitcast.i32.f32" "bitcast.u32.f32"
    "bitcast.f64.i64" "bitcast.f64.u64"
    "bitcast.i64.f64" "bitcast.u64.f64"))

(defconst rza-typed-opcode-regexp
  (concat "\\_<" (regexp-opt rza-typed-opcode-bases)
          "\\.\\(?:i8\\|u8\\|i16\\|u16\\|i32\\|u32\\|i64\\|u64\\)\\_>"
          "\\|\\_<\\(?:shr\\|slt\\)\\.\\(?:i8\\|i16\\|i32\\|i64\\)\\_>"
          "\\|\\_<ult\\.\\(?:u8\\|u16\\|u32\\|u64\\)\\_>"
          "\\|\\_<" (regexp-opt '("mov" "load" "store" "add" "sub" "mul" "div"
                                  "feq" "fne" "flt" "fle" "fgt" "fge"))
          "\\.\\(?:f32\\|f64\\)\\_>"
          "\\|\\_<" (regexp-opt rza-conversion-opcodes) "\\_>"))

(defconst rza-scalar-types
  '("u8" "i8" "u16" "i16" "u32" "i32" "i64" "u64" "f32" "f64"))

(defconst rza-font-lock-keywords
  `((,rza-typed-opcode-regexp . font-lock-keyword-face)
    (,(regexp-opt rza-opcodes 'symbols) . font-lock-keyword-face)
    (,(regexp-opt rza-scalar-types 'symbols) . font-lock-builtin-face)
    ("\\<[A-Z][A-Za-z0-9_]*\\>" . font-lock-type-face)
    ("\\_<field\\_>" . font-lock-constant-face)
    ("%r\\(?:[0-9]\\|1[0-5]\\)\\_>" . font-lock-variable-name-face)
    ("\\]\\.\\([a-z_][a-z0-9_]*\\)" 1 font-lock-builtin-face)
    ("\\_<proc[ \t]+\\([a-z_][a-z0-9_]*\\)" 1 font-lock-function-name-face)
    ("^[ \t]*\\([a-z_][a-z0-9_]*\\):" 1 font-lock-function-name-face)
    ("\\(?:^\\|[^A-Za-z0-9_]\\)\\(-?0x[0-9A-Fa-f]+\\)\\_>" 1 font-lock-constant-face)
    ("\\(?:^\\|[^A-Za-z0-9_]\\)\\(-?[0-9]+\\)\\_>" 1 font-lock-constant-face)))

(defvar rza-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\; "<" table)
    (modify-syntax-entry ?\n ">" table)
    table))

(define-derived-mode rza-mode prog-mode "RZA"
  "Major mode for RZA assembly."
  :syntax-table rza-mode-syntax-table
  (setq-local font-lock-defaults '(rza-font-lock-keywords))
  (setq-local comment-start "; ")
  (setq-local comment-end ""))

(add-to-list 'auto-mode-alist '("\\.rza\\'" . rza-mode))

(provide 'rza-mode)
