#!/usr/bin/env bash
set -euo pipefail

# Check Emacs Lisp files are properly indented

files=$(git ls-files '*.el')
status=0

for file in $files; do
  emacs --batch "$file" \
        --eval "(indent-region (point-min) (point-max))" \
        -f save-buffer
done

if ! git diff --quiet; then
  echo "Indentation issues found in the following files:" >&2
  git diff --name-only >&2
  status=1
fi

git checkout -- $files
exit $status
