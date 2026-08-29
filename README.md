<h1 align="center" style="border-bottom: none;">
    <b><i>op.el</i></b> &mdash;1Password integration for Emacs</small>
</h1>

<p align="center">
  <a href="https://github.com/renatgalimov/op.el/actions/workflows/test.yml?query=branch%3Amain"><img src="https://img.shields.io/github/actions/workflow/status/renatgalimov/op.el/test.yml?branch=main&style=for-the-badge&label=Run%20Unit%20Tests" alt="Run Unit Tests"></a>
</p>

![image](https://github.com/user-attachments/assets/c447023c-7bbd-42ce-9c5c-ccfdff24a417)

# op.el

1Password integration for Emacs.

- Call `op` from Emacs without repeated authentication prompts
- Share that authenticated session with `op` in your terminal buffers
- Read secrets anywhere via `op-read`
- Use 1Password as an `auth-source` backend

---

## Why

Using the 1Password CLI (`op`) inside Emacs is annoying:

- It may re-request authentication on every call
- There's no simple way to fetch secrets inline
- Emacs packages still expect `.authinfo` or `pass`

This package fixes all of that.

## Installation

Requires Emacs 29.1+ and the [1Password CLI](https://developer.1password.com/docs/cli/get-started/) (`op`).

### use-package (with vc)

```elisp
(use-package op
  :vc (:url "https://github.com/renatgalimov/op.el" :branch "main"))
```

### use-package (with vc) + auth-source

```elisp
(use-package op-auth-source
  :vc (:url "https://github.com/renatgalimov/op.el" :branch "main")
  :config
  (op-auth-source-enable))
```

### Manual

Clone the repository and add it to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/op.el")
(require 'op)
```

## auth-source Integration

The `op-auth-source` package provides an [auth-source](https://www.gnu.org/software/emacs/manual/html_mono/auth.html) backend so that Emacs packages like smtpmail, Gnus, ERC, and others can fetch credentials from 1Password automatically.

### Setup

```elisp
(require 'op-auth-source)
(op-auth-source-enable)
```

This adds `1password` to your `auth-sources` list. Emacs will then consult 1Password when any package calls `auth-source-search`.

### 1Password Setup

Tag the items you want Emacs to access with `emacs-auth-source` in 1Password. The backend only searches items with this tag.

Items are matched by their **fields**.  The backend maps each search criterion to one or more field labels:

| Criterion | Matched field labels              |
|-----------|-----------------------------------|
| `:host`   | `host`, `server`, `hostname`      |
| `:user`   | `user`, `username`, `email`       |
| `:port`   | `port`, `port number`             |

Any other criterion key is matched against a field whose label equals the key name (e.g., `:security` matches a field labeled `security`).

A search must include at least one non-nil criterion; an empty search returns no results.

### How It Works

When a package searches for credentials (e.g., `:host "smtp.gmail.com" :user "alice@gmail.com" :port 587`), the backend:

1. Runs `op item list --tags emacs-auth-source --format json` to find tagged items
2. Fetches full item details via `op item get`
3. Matches each criterion against the item's fields by label
4. Returns the password via `op item get <id> --fields label=password`

### Disabling

```elisp
(op-auth-source-disable)
```

## Sharing the session with terminal buffers

`op.el` keeps one authenticated terminal open and runs every command through it,
which is why it stops prompting after the first fingerprint. A shell running in
vterm, `M-x shell` or `compile` is a different terminal, so `op` there prompts
again.

`op-shim-mode` closes that gap. It puts an `op` on `PATH` for Emacs's children
that forwards the invocation to the terminal Emacs already authenticated:

```elisp
(require 'op-shim)
(op-shim-mode 1)
```

Run `op` in a vterm buffer as usual. `op read`, `op item get`, `op item list`,
`op inject` and `op document get` are forwarded and do not prompt. Output is
byte-exact, so redirecting a document to a file works.

Commands that need your own terminal are not forwarded and behave exactly as
before, prompting when they must: `op run`, `op plugin run`, `op signin`,
`op signout`, `op update`, `op account add` and `op account forget`. Setting
`OP_SHIM_DISABLE=1` bypasses forwarding for a single call.

Each forwarded call blocks Emacs while it runs, typically well under a second.

### What this does and does not protect

A request is served only when the kernel reports that the connecting process
descends from your Emacs. The pid comes from `lsof`, not from the request, so a
caller cannot claim to be someone else. The socket is created `0600` inside a
`0700` directory, and it disappears when you disable the mode or exit Emacs.

**This is not a defence against an attacker already running as your user.** Such
an attacker can read your Emacs process's memory and environment directly, so
the account is compromised with or without this mode. What the ancestry check
buys you is a barrier against unrelated processes on the machine — a stray
script, a background daemon, a compromised package install — that would
otherwise find an open socket and use it.

## Contributing

Write unit tests with [Buttercup](https://github.com/jorgenschaefer/emacs-buttercup) and name each spec using the pattern **X when Y should Z**.

Install the development dependencies with [Cask](https://cask.readthedocs.io/en/latest/) and run the suite via `./scripts/run-tests.sh` before submitting a pull request.
