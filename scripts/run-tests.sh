#!/usr/bin/env bash
set -euo pipefail

# Run the Buttercup test suite
buttercup_dir=$(echo /usr/share/emacs/site-lisp/elpa/buttercup-*)
emacs --batch -Q -L . \
      -L "$buttercup_dir" \
      -l test/run-tests.el
