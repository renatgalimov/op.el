#!/usr/bin/env bash
set -euo pipefail

# Run the ERT suite
emacs --batch -Q -L . -l test/run-tests.el
