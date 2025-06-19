# Agent Contributions

Agent guidelines for `renatgalimov/op.el` GitHub repo.

GitHub: `renatgalimov/op.el`

## Git

This repository uses Git history responsively. Use `git log` to expand your context and see the reasons of why something was done.

## Markdown

When writing a Markdown or OrgMode file, don't break lines in the middle of a sentence to maintain line width.

## emacs-lisp

After modifying an emacs-lisp file, automatially format it with:

```
  emacs --batch "$file" \
        --eval "(indent-region (point-min) (point-max))" \
        -f save-buffer
```

# GitHub CLI (`gh`) usage

The environment **has to** have a working `gh` installation. 
`gh auth status` should succeed; otherwise report an error and stop operation.


The environment has `gh` installed. You cannot freely use `gh` as it uses POST requests, and the agent environment forbids POST requests. Instead - you should use `gh` like `gh api repos/renatgalimov/op.el/issues/<issue id>`


# Agent Environment Setup

Agent environment Setup code is located in `scripts/setup-agent.sh`