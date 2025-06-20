#!/usr/bin/env bash
set -euo pipefail

buttercup_dir=$(echo /usr/share/emacs/site-lisp/elpa/buttercup-*)
      -L "$buttercup_dir" \
cask install
cask exec emacs --batch -Q -L . -L test -l test/run-tests.el
