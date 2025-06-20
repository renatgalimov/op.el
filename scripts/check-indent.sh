#!/usr/bin/env bash
set -euo pipefail

# Check Emacs Lisp files are properly indented (without modifying them)

files=$(git ls-files '*.el')
status=0

for file in $files; do
  emacs --batch "$file" \
    --eval "(progn (indent-region (point-min) (point-max)) (when (buffer-modified-p) (kill-emacs 1)))" || {
      echo "Indentation issue in $file" >&2
      status=1
    }
done

exit $status
