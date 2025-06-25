#!/usr/bin/env bash
set -euo pipefail

# Install dependencies and run the Buttercup suite
cask install
cask exec emacs --batch -Q -L . -L test -l test/run-tests.el


