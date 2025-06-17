# Agent Contributions
## Markdown

When writing a Markdown or OrgMode file, don't break lines in the middle of a sentence to maintain line width. 

## emacs-lisp

After modifying an emacs-lisp file, automatially format it with:

```
  emacs --batch "$file" \
        --eval "(indent-region (point-min) (point-max))" \
        -f save-buffer
```