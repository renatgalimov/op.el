<h1 align="center" style="border-bottom: none;">
    <b><i>op.el</i></b> &mdash;1Password integration for Emacs</small>
</h1>

<p align="center">
  <a href="https://github.com/renatgalimov/op.el/actions/workflows/test.yml?query=branch%3Amain"><img src="https://img.shields.io/github/actions/workflow/status/renatgalimov/op.el/test.yml?branch=main&style=for-the-badge&label=Run%20Unit%20Tests" alt="Run Unit Tests"></a>
</p>

![image](https://github.com/user-attachments/assets/c447023c-7bbd-42ce-9c5c-ccfdff24a417)

# op.el

1Password integration for Emacs

This repository uses GitHub Actions to run Buttercup tests and verify that all Emacs Lisp files are properly indented. The indentation check can also be run locally via `./scripts/check-indent.sh`.

## Contributing

Write unit tests with [Buttercup](https://github.com/jorgenschaefer/emacs-buttercup) and name each spec using the pattern **X when Y should Z**.

Install the development dependencies with [Cask](https://cask.readthedocs.io/en/latest/) and run the suite via `./scripts/run-tests.sh` before submitting a pull request.
