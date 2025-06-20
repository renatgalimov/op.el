# Agent Contributions

Agent guidelines for `renatgalimov/op.el` GitHub repo.

GitHub: `renatgalimov/op.el`

## Git

This repository uses Git history responsively. 
Use `git log` to expand your context and see the reasons behind certain actions.

## Markdown

When writing a Markdown or OrgMode file, don't break lines in the middle of a sentence to maintain line width.

## emacs-lisp

After modifying an emacs-lisp file, automatially format it with:

```
  emacs --batch "$file" \
        --eval "(indent-region (point-min) (point-max))" \
        -f save-buffer
```

# Testing

The environment **should have** `op` tool installed. If it's not available - *stop the operation*;

# GitHub CLI (`gh`) usage

The environment **has to** have a working `gh` installation. 
`gh auth status` should succeed; otherwise report an error and stop operation.

The environment has `gh` installed.
When working with - you could use only `gh api` command, like `gh api repos/renatgalimov/op.el/issues/<issue id>`
Avoid calling other `gh` commands as they use POST requests, and the agent environment forbids POST requests.


# Agent Environment Setup

## Setup code

Located in `scripts/setup-agent.sh`

## Secrets

`_GH_TOKEN` - needed to read GitHub issues.

## Domains
```
downloads.1password.com
```