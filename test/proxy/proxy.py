"""mitmproxy addon: explicit live forwarding or offline read-only replay."""
import os
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from mitmproxy import ctx, http, io

MODE = os.environ.get("OP_PROXY_MODE")
if MODE not in {"forward", "replay"}:
    raise ValueError("OP_PROXY_MODE must be forward or replay")


def key(request):
    url = urlsplit(request.url)
    query = urlencode([(k, v) for k, v in parse_qsl(url.query, keep_blank_values=True) if k != "__t"])
    url = urlunsplit((url.scheme, url.netloc, url.path, query, url.fragment))
    headers = tuple(sorted((name.lower(), value) for name, value in request.headers.fields if name.lower() != b"x-agilebits-mac"))
    return (request.method, url, request.raw_content, headers)


class Proxy:
    def __init__(self):
        self.responses = {}
        if MODE == "replay":
            with open(os.environ["OP_PROXY_RECORDING"], "rb") as recording:
                for flow in io.FlowReader(recording).stream():
                    if isinstance(flow, http.HTTPFlow) and flow.response and flow.request.method == "GET":
                        self.responses[key(flow.request)] = flow.response.copy()

    def running(self):
        if MODE == "replay":
            ctx.options.update(connection_strategy="lazy", upstream_cert=False)

    def server_connect(self, data):
        if MODE == "replay":
            data.server.error = "offline replay blocks all upstream connections"

    def request(self, flow):
        if MODE == "replay":
            response = self.responses.get(key(flow.request)) if flow.request.method == "GET" else None
            flow.response = response.copy() if response else http.Response.make(502, b"offline replay: request not permitted or not recorded\n")


addons = [Proxy()]
