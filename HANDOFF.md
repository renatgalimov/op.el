# Handoff: op.el issue #9 and real-CLI test infrastructure

## What the user wants

- Implement [issue #9](https://github.com/renatgalimov/op.el/issues/9): an idiomatic Emacs completion-at-point function for `op://` secret references. The issue asks for a simple CAPF as a first approximation and an experience like `project-find-file`: for example, typing `Prod` should be able to find `op://Engineering/Azure Production Password`.
- Test the feature and, if feasible, provide asciinema recordings demonstrating it.
- The user asked to install the `dietrichgebert/ponytail` plugin and ensure Ponytail Review passes. Ponytail and Ponytail Review **skills** were installed; a plugin was not found in the catalog. No review has been run or passed yet.
- The user requested a real-CLI, mitmproxy-based HTTP test setup, explicitly saying not to reuse the old naming style and to discard `bin/op.py` in favor of real `op`. They asked for this test-infrastructure work in a **separate PR** from issue #9.
- Most recently, the user asked `@code-review` to run `/ponytail-review`. This session had no `message_agent` tool, so it did not contact that agent. The user intends to continue in a Hermes Bot Chat. Ask `@code-review` for the review there; clarify review scope if needed. The existing local commit is `e933a73`, but it is not an implementation of issue #9 or the proxy.

## Repository state

- Repository: `/home/agent/projects/op.el`; branch `main`.
- Before writing this handoff: clean working tree; `main` was one commit ahead of `origin/main`. Local commit: `e933a73 docs: update agent access guidance and project idea`.
- GitHub `main` was checked via the authorized agent-iap GitHub upstream at `9853d6a31d64d6de64e179a3bd8ca4abf7ccc2c0`; the branch was successfully rebased against that commit and was already up to date. Recheck state and remote before further work.
- `HANDOFF.md` is the only file created in the repository during this handoff. It is untracked unless the user or another agent changes that. Do not commit it or include it in a PR without an explicit decision.
- No issue #9 implementation, production proxy harness, test-infrastructure branch, PR, project test run, lint run, or asciinema recording has been completed in this session. Do not claim otherwise.

## Project rules and conflict to resolve

Read `AGENTS.md` before changing the repository. It requires `op` and `gh`, a rebase against the repository's `main`, and GitHub access through authenticated `gh` or the `vpetersson/agent-iap` GitHub upstream. `gh auth status` was not authenticated; the IAP GitHub API was available and used successfully. Only `gh api` and `gh auth status` are permitted when using `gh`.

The existing test instructions in `AGENTS.md` require all test `op` invocations to go through `bin/op.py`, and require human-created fixture entries generated with `OP_MODE=verify`. Those instructions conflict with the user's request to discard `bin/op.py` and use the real CLI through mitmproxy. Resolve the project-instruction change explicitly with the user before replacing that route; do not silently bypass it or fabricate fixture data. Existing rules also forbid mocking `op` with Emacs Lisp `cl-letf` around `call-process`.

Do not commit, push, or rewrite history unless authorized. The user requested a separate PR for the infrastructure work, but no PR has yet been created. Preserve the existing ahead-of-origin commit and do not assume it is yours.

## Experiments completed with the real `op`

- `op` 2.41.1 was installed. A local, explicitly trusted mitmproxy CA worked using `SSL_CERT_FILE`, and the CLI sent traffic through `HTTPS_PROXY`. No global CA installation was required.
- The user signed into a test account in GNU screen. Metadata-only tracing observed a sign-in exchange; it did **not** prove fresh-sign-in replay and did not record authentication bodies or headers.
- Through the real CLI and forwarding proxy, a disposable vault was used to create, read, edit, and delete Login, Password, Secure Note, API Credential, and Credit Card items. Each deletion was checked via the CLI's item-not-found error. Listing and tag filtering returned five items; reading a dummy Login password worked. The vault was confirmed absent from the vault list after cleanup. These were **live-service tests**, not offline mock tests.
- Chinese, right-to-left text, composed/decomposed Unicode, tabs, newlines, and U+0001 survived the exercised create/read/update paths. NUL was exercised in a JSON template through create/delete. A zero-width joiner in an emoji sequence was removed in tested Login and Credit Card cases; the responsible component was not established.
- A same-session `op item list` GET recording/replay returned equivalent item data ignoring ordering. That establishes only a narrow replay scenario, not general CRUD or fresh authentication.
- A fixed CRUD response replay initially appeared successful. A negative test using a **different input title** demonstrated that a later read still returned the old recorded title: this is not stateful behavior. The prototype was changed to reject replayed mutation requests with HTTP 501; that rejection was verified. Unknown replay traffic must also fail closed. Do not present the former green run as a working CRUD mock.
- Structural tracing showed encrypted request/response envelopes and changing identifiers. Whether a practical protocol-aware offline emulator can be implemented remains an open question. Fresh authentication was not replayed. Avoid assuming URL-only matching or recorded responses can support arbitrary writes.

## Scratch artifacts and security

The following are disposable prototypes, not project code, and the scratch directory can be pruned after inactivity. Check for their existence before relying on them:

- `/home/agent/.hermes/cache/scratch/transaction-proxy.py`: experimental mitmproxy addon; replay writes intentionally disabled.
- `/home/agent/.hermes/cache/scratch/transaction-probe.py`: real-CLI single-item CRUD probe.
- `/home/agent/.hermes/cache/scratch/op-live-probe.py`: five-category live CRUD probe.
- `/home/agent/.hermes/cache/scratch/op-unicode-probe.py` and `op-emoji-diff.py`: character probes.
- `/home/agent/.hermes/cache/scratch/protocol-shapes.py`: structural metadata-only logging prototype.
- Private test-account recordings and the local proxy CA are also under scratch. They can contain sensitive account information and must not be printed, shared, or committed without careful review. Last checked recording and CA directories were mode `0700`, with no group/world-readable files.

The temporary proxy was stopped after the experiments. Screen sessions `op-test` and `op-signin` existed at the last check; `op-signin` was attached. Their environment and authentication may have changed or expired. The proxy-configured shells will not reach the service through the stopped local proxy until it is restarted or their environment is changed. Do not print environment variables, session tokens, private keys, account responses, or credential files. A session credential was previously exposed in chat; the user was advised to revoke it and avoid posting replacements.

## Suggested next steps

1. In Bot Chat, send a properly scoped Ponytail Review request to `@code-review` and obtain its actual findings. Do not claim a review passed without its result.
2. Agree with the user how to resolve the `AGENTS.md` test-rule conflict and whether to pursue the substantially more complex stateful offline protocol emulator versus a separate live-integration test strategy. Do not describe a static response player or a forwarding-only proxy as a complete stateful mock.
3. For test-infrastructure work, use a separate branch/PR and real `op` as requested, and test changed-input CRUD, error paths, fresh sessions, Unicode, cleanup, and fail-closed network behavior. Never commit unreviewed account captures or authentication material.
4. Implement issue #9 separately, using native Emacs completion conventions and appropriate tests. Run the project's relevant tests and lint, request Ponytail Review, and produce an asciinema demo if feasible. Check dependencies first: Cask, asciinema, and Buttercup on the Emacs load path were absent when last checked.
