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
- Read secrets anywhere via `op-read`
- Use 1Password as an `auth-source` backend

---

## Why

Using the 1Password CLI (`op`) inside Emacs is annoying:

- It may re-request authentication on every call
- There's no simple way to fetch secrets inline
- Emacs packages still expect `.authinfo` or `pass`

This package fixes all of that.

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

## Contributing

Write unit tests with [Buttercup](https://github.com/jorgenschaefer/emacs-buttercup) and name each spec using the pattern **X when Y should Z**.

Install the development dependencies with [Cask](https://cask.readthedocs.io/en/latest/) and run the suite via `./scripts/run-tests.sh` before submitting a pull request.
