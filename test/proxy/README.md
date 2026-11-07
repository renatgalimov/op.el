# Real `op` proxy harness

`proxy.py` is a mitmproxy addon, not an `op` replacement. Install mitmproxy separately. Run these commands from the repository root; bind only to loopback and keep the recording and mitmproxy CA directory private. Forward mode sends requests to the real upstream, including writes. `-w` records traffic verbatim and may capture credentials, tokens, and vault data. Use a disposable account/entries, store recordings outside the repository, and review and sanitize before sharing. Never commit raw recordings.

```sh
# Live forwarding, with optional raw recording (choose private paths).
OP_PROXY_MODE=forward mitmdump --listen-host 127.0.0.1 --listen-port 8080 \
  --set confdir="$HOME/.mitmproxy-op" -s test/proxy/proxy.py \
  -w /private/path/recording.mitm

# Offline replay: recording must already exist and be readable.
OP_PROXY_MODE=replay OP_PROXY_RECORDING=/private/path/recording.mitm \
  mitmdump --listen-host 127.0.0.1 --listen-port 8080 \
  --set confdir="$HOME/.mitmproxy-op" -s test/proxy/proxy.py
```

Configure the client to use `http://127.0.0.1:8080` as its HTTP(S) proxy and trust the generated mitmproxy CA. For 1Password sign-in, follow `AGENTS.md`: start the proxy and a GNU screen session with the proxy and CA configured, then ask a human to attach and sign in; never request credentials or session tokens in chat. Proxy variables and certificate trust must be configured for the actual client environment, not just the parent test process.

Replay serves recorded GETs matching the method, URL, raw body and request headers, except the `__t` timestamp query parameter and `X-AgileBits-MAC` header, which vary across real `op` requests. Header names are matched case-insensitively and their order is ignored. If duplicate keys occur, the last response wins. It returns 502 for every other request, including recorded POSTs and unrecorded reads, and independently blocks upstream connections. Changing session headers or other dynamic values may prevent matches. It is not a stateful backend, cannot perform CRUD or establish fresh authentication, and successful playback does not prove a fresh sign-in. Some APIs use POST for reads; those are intentionally rejected too. Use live forwarding for writes and fresh-auth checks.

Run isolated integration tests (they generate temporary recordings only against a local non-1Password HTTP server):

```sh
MITMDUMP=/path/to/mitmdump make test-proxy
```

For all real-CLI Buttercup tests, use a disposable signed-in account. From the proxy-configured session, run:

```sh
make test-live
```

This creates a uniquely named temporary vault and five test items, runs the suite with all live cases enabled, then deletes the items and vault and verifies their absence. Cleanup failures report the vault name and ID for manual recovery. If vault creation has an ambiguous outcome, inspect the disposable account for the reported unique name; verify ownership before deleting anything. On timeout or interruption the vault is retained for manual cleanup after stopping all test processes. The runner refuses non-loopback proxies, bypass settings, or missing CA configuration. The tests traverse every account visible to `op`, so use an isolated CLI configuration containing only the disposable account.

`make test` runs the pure suite without credentials; live cases are skipped unless the `OP_TEST_*` and `OP_AUTH_TEST_*` variables documented in the test files are configured. A successful run with skipped cases is not equivalent to `make test-live`.

Record a live run before attempting same-session replay. The recording and session are private; replay has not been established across fresh sessions.
