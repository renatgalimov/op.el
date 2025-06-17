#!/usr/bin/env bash
set -euo pipefail

# Compile ELisp to eln
emacs --batch -Q -f batch-native-compile op.el

# Run tests
emacs --batch -Q -L . -l test/run-tests.el
