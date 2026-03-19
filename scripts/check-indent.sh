#!/bin/sh
set -eu

# Re-indent all tracked Emacs Lisp files in place.

# Mark the working directory as safe for containers where the checkout
# is owned by a different user (e.g. GitHub Actions with Docker).
git config --global --add safe.directory "$(pwd)"

files=$(git ls-files '*.el')
status=0

for file in $files; do
  emacs --batch "$file" \
    --eval "(progn (indent-region (point-min) (point-max)) (when (buffer-modified-p) (save-buffer)))" || {
      echo "Failed to indent $file" >&2
      status=1
    }
done

exit $status
