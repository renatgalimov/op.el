# Facts

GitHub repository: `renatgalimov/op.el`

# Workflow

- Always rebase your branch against the "main" branch in the `renatgalimov/op.el` GitHub repo. If you fail to rebase, stop and report immediately.
- Implement the changes

# Git

This repository uses Git history responsively. 
Use `git log` to expand your context and see the reasons behind certain actions.

# Markdown

When writing a Markdown or OrgMode file, don't break lines in the middle of a sentence to maintain line width.

# emacs-lisp

After modifying an emacs-lisp file, automatially format it with:

```
  emacs --batch "$file" \
        --eval "(indent-region (point-min) (point-max))" \
        -f save-buffer
```

# Testing

The environment **should have** `op` tool installed. If it's not available - *stop the operation*;

## Test-Driven Development

Before implementing a new feature or fixing a bug, first write a Buttercup test that describes the expected behavior. Run the test to ensure it fails, then implement the feature or fix, and re-run the test to ensure it passes.

# GitHub CLI (`gh`) usage

- The environment has `gh` installed
  - Only `gh api` and `gh auth status` commands may be used; avoid other subcommands.
  - The environment has to have an authenticated `gh`; `gh auth status` should succeed or report an error and stop.

- To read a GitHub issue content use `gh api repos/renatgalimov/op.el/issues<issue id>` subcommand.

# Agent Environment Setup

## Setup code

Located in `scripts/setup-agent.sh`

## Secrets

`_GH_TOKEN` - needed to read GitHub issues.

## Domains
```
downloads.1password.com
```