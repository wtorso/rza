#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

for tool in emacs vim; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FATAL: $tool is required" >&2
        exit 2
    fi
done

cleanup() {
    rm --force editors/emacs/rza-mode.elc
}
trap cleanup EXIT

emacs -Q --batch -L editors/emacs --eval '(setq byte-compile-error-on-warn t)' \
    -f batch-byte-compile editors/emacs/rza-mode.el
emacs -Q --batch -L editors/emacs -L editors/tests/emacs \
    -l editors/tests/emacs/rza-mode-test.el -f ert-run-tests-batch-and-exit
vim -Nu NONE -n -es -S editors/tests/vim/rza.vim
printf '\nLightweight editor tests passed\n'
