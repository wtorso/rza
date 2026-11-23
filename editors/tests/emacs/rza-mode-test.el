;;; -*- lexical-binding: t; -*-

(require 'ert)
(require 'rza-mode)

(defconst rza-test-opcodes
  '("cav" "res" "med" "view" "raise" "decay" "probe" "load" "loadb"
    "mov" "store" "storeb" "slt" "inc" "dec" "await" "print"
    "jmp" "brz" "brnz" "call" "proc" "casc" "acasc" "endc" "ret"
    "layout" "add" "sub" "mul" "div" "mod" "and" "or" "xor"
    "shl" "shr" "ushr" "cadd" "csub" "cmul" "cinc" "cdec" "crc32c"))

(defmacro rza-test-with-fixture (&rest body)
  `(with-temp-buffer
     (insert-file-contents "editors/tests/fixtures/sample.rza")
     (rza-mode)
     (font-lock-mode 1)
     (font-lock-ensure)
     ,@body))

(defun rza-test-face-at (line column)
  (goto-char (point-min))
  (forward-line (1- line))
  (move-to-column column)
  (get-text-property (point) 'face))

(ert-deftest rza-test-opcodes-have-keyword-face ()
  (dolist (opcode rza-test-opcodes)
    (with-temp-buffer
      (insert opcode)
      (rza-mode)
      (font-lock-mode 1)
      (font-lock-ensure)
      (should (eq (get-text-property 1 'face) 'font-lock-keyword-face)))))

(defconst rza-test-typed-opcodes
  (append
   (mapcan (lambda (base)
             (mapcar (lambda (type) (concat base "." type))
                     '("i8" "u8" "i16" "u16" "i32" "u32" "i64" "u64")))
           '("mov" "load" "store" "add" "sub" "mul" "inc" "dec"
             "cadd" "csub" "cmul" "cinc" "cdec" "and" "or" "xor"
             "div" "mod" "shl" "ushr"))
   '("shr.i8" "slt.i8" "ult.u8" "shr.i16" "slt.i16" "ult.u16"
     "shr.i32" "slt.i32" "ult.u32" "shr.i64" "slt.i64" "ult.u64")))

(defconst rza-test-floating-opcodes
  (append
   (mapcan (lambda (base)
             (mapcar (lambda (type) (concat base "." type)) '("f32" "f64")))
           '("mov" "load" "store" "add" "sub" "mul" "div"
             "feq" "fne" "flt" "fle" "fgt" "fge"))
   (mapcan (lambda (float)
             (mapcan (lambda (type)
                       (list (concat "cvt." float "." type)
                             (concat "cvt." type "." float)))
                     '("i8" "u8" "i16" "u16" "i32" "u32" "i64" "u64")))
           '("f32" "f64"))
   '("cvt.f64.f32" "cvt.f32.f64")
   (mapcan (lambda (pair)
             (let ((float (nth 0 pair)) (signed (nth 1 pair)) (unsigned (nth 2 pair)))
               (list (concat "bitcast." float "." signed)
                     (concat "bitcast." float "." unsigned)
                     (concat "bitcast." signed "." float)
                     (concat "bitcast." unsigned "." float))))
           '(("f32" "i32" "u32") ("f64" "i64" "u64")))))

(ert-deftest rza-test-active-typed-opcodes-have-keyword-face ()
  (should (= (length rza-conversion-opcodes) 42))
  (let ((active (append rza-test-typed-opcodes rza-test-floating-opcodes)))
    (should (= (length active) 240))
    (dolist (opcode active)
      (with-temp-buffer
        (insert opcode)
        (rza-mode)
        (font-lock-mode 1)
        (font-lock-ensure)
        (should (eq (get-text-property 1 'face) 'font-lock-keyword-face))
        (should (eq (get-text-property (length opcode) 'face)
                    'font-lock-keyword-face))))))

(ert-deftest rza-test-inactive-typed-opcodes-have-no-keyword-suffix ()
  (dolist (opcode '("shr.u8" "slt.u8" "ult.i8" "shr.u16" "slt.u16" "ult.i16"
                    "shr.u32" "slt.u32" "ult.i32" "shr.u64" "slt.u64" "ult.i64"
                    "ult" "loadb.u8" "loadb.u16" "loadb.u32" "loadb.u64"
                    "crc32c.i32" "print.i32" "cvt.i64" "cvt.u64"
                    "mod.f32" "mod.f64" "cadd.f32" "feq.i32"
                    "cvt.f32.f32" "cvt.i32.i64" "bitcast.f64.u32"
                    "mov.f16" "load.bf16" "cvt.f16.f32"))
    (with-temp-buffer
      (insert opcode)
      (rza-mode)
      (font-lock-mode 1)
      (font-lock-ensure)
      (when (equal opcode "ult")
        (should (not (eq (get-text-property 1 'face) 'font-lock-keyword-face))))
      (when (string-match "\\." opcode)
        (should (not (eq (get-text-property (length opcode) 'face)
                         'font-lock-keyword-face)))))))

(ert-deftest rza-test-layout-and-scalar-types ()
  (rza-test-with-fixture
   (should (eq (rza-test-face-at 1 7) 'font-lock-type-face))
   (should (eq (rza-test-face-at 1 18) 'font-lock-builtin-face))
   (should (eq (rza-test-face-at 1 29) 'font-lock-builtin-face))
   (should (eq (rza-test-face-at 2 20) 'font-lock-type-face))
   (should (eq (rza-test-face-at 12 37) 'font-lock-builtin-face))
   (should (eq (rza-test-face-at 12 54) 'font-lock-builtin-face))
   (should (eq (rza-test-face-at 18 21) 'font-lock-builtin-face))
   (should (eq (rza-test-face-at 18 31) 'font-lock-builtin-face))
   (should (eq (rza-test-face-at 19 18) 'font-lock-builtin-face))
   (should (not (eq (rza-test-face-at 1 7)
                    (rza-test-face-at 1 18))))))

(ert-deftest rza-test-registers-and-field-constant ()
  (rza-test-with-fixture
   (should (eq (rza-test-face-at 4 4) 'font-lock-variable-name-face))
   (should (eq (rza-test-face-at 5 4) 'font-lock-variable-name-face))
   (should (eq (rza-test-face-at 2 13) 'font-lock-constant-face))
   (should (eq (rza-test-face-at 3 25) 'font-lock-constant-face))
   (should (null (rza-test-face-at 11 4)))))

(ert-deftest rza-test-number-forms ()
  (rza-test-with-fixture
   (should (eq (rza-test-face-at 4 9) 'font-lock-constant-face))
   (should (eq (rza-test-face-at 5 10) 'font-lock-constant-face))
   (should (eq (rza-test-face-at 2 26) 'font-lock-constant-face))
   (should (eq (rza-test-face-at 7 23) 'font-lock-constant-face))))

(ert-deftest rza-test-selectors-and-labels ()
  (rza-test-with-fixture
   (should (eq (rza-test-face-at 6 24) 'font-lock-builtin-face))
   (should (eq (rza-test-face-at 7 27) 'font-lock-builtin-face))
   (should (eq (rza-test-face-at 8 5) 'font-lock-function-name-face))))

(ert-deftest rza-test-comments-mask-instructions-and-registers ()
  (rza-test-with-fixture
   (should (eq (rza-test-face-at 10 0) 'font-lock-comment-delimiter-face))
   (should (eq (rza-test-face-at 10 2) 'font-lock-comment-face))
   (should (eq (rza-test-face-at 10 9) 'font-lock-comment-face))
   (should (eq (rza-test-face-at 10 13) 'font-lock-comment-face))))

(ert-deftest rza-test-proc-contract-name ()
  (with-temp-buffer
    (insert "proc convert(input_m: ro, result_m: rw):")
    (rza-mode)
    (font-lock-mode 1)
    (font-lock-ensure)
    (should (eq (get-text-property 6 'face) 'font-lock-function-name-face))))

(ert-deftest rza-test-filetype-and-comment-configuration ()
  (should (equal (cdr (assoc "\\.rza\\'" auto-mode-alist)) 'rza-mode))
  (with-temp-buffer
    (rza-mode)
    (should (equal comment-start "; "))
    (should (equal comment-end ""))))


(ert-deftest rza-test-float-scalar-types ()
  (with-temp-buffer
    (insert "layout FloatPair: single:f32, double:f64")
    (rza-mode)
    (font-lock-mode 1)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "f32")
    (should (eq (get-text-property (1- (point)) 'face) 'font-lock-builtin-face))
    (search-forward "f64")
    (should (eq (get-text-property (1- (point)) 'face) 'font-lock-builtin-face))))
