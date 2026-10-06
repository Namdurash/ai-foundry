#!/usr/bin/env python3
"""A stand-in for the Trello REST API, for scripts/check-board.sh.

Implements exactly the endpoints lib/board.sh calls, against an in-memory
store, so the adapter's URL shapes, parameters, auth header and JSON parsing
are exercised offline. It is not Trello: it proves the adapter talks the way
the documented API listens, not that Trello behaves.

    python3 scripts/mock-trello.py <port>

One board, "b1", pre-seeded with two lists ("Backlog", "Done") so `aif board
init --create-lists` has both a name to map and four lists to create.
GET /_state dumps everything for the check's assertions; GET
/_fail/comments/on and /_fail/comments/off make every comment fail, the way a
board that stops answering does, and back; GET /_desc/limit/off and /on lift
and restore Trello's 16384-character limit on a card's description, for the
one check that needs a card no real board would hold (a 76 KiB description,
past a pipe buffer, docs/DEFECTS.md 5.1).

Comments are held to what Trello holds them to: 1 to 16384 characters, counted
as JavaScript counts them (UTF-16 code units), and text that is not UTF-8 is
refused with a 400 — what the project saw a comment cut through a Cyrillic
letter get (docs/DEFECTS.md 10.1).

Faults, for the adapter's retry and its loud failures (docs/DEFECTS.md 13.8,
14.7). When the environment variable MOCK_FAULT_FILE names a file that exists,
every request reads it as one line, `<code> <count> [<path-substring>]`, and
while count > 0 and the request's path — its query string included, so that
`actions?` is the comments GET and never the comment's POST — contains the
substring (any request when none is given) the answer is <code> — with
`Retry-After: 0` on a 429 — and the count
in the file goes down by one; at 0 the file is removed. So a check writes the
line between two commands, runs the next, and reads the outcome off the file:
gone, every fault was served and the adapter came back for the rest; still
there, it did not — which is what a POST the adapter must not retry leaves
behind. The mock's own /_state, /_fail and /_desc routes are never faulted.
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

STATE = {"lists": {}, "cards": {}, "comments": {}, "labels": {}, "seq": 0, "log": []}
BOARD = "b1"


def new_id(prefix):
    STATE["seq"] += 1
    return f"{prefix}{STATE['seq']}"


for _name in ("Backlog", "Done"):
    _lid = new_id("l")
    STATE["lists"][_lid] = {"id": _lid, "name": _name, "idBoard": BOARD,
                            "pos": STATE["seq"] * 1000, "closed": False}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # quiet
        pass

    def _params(self):
        q = parse_qs(urlparse(self.path).query)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        self._raw = body
        if body:
            for k, v in parse_qs(body, keep_blank_values=True).items():
                q[k] = v
        return {k: v[0] for k, v in q.items()}

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _auth(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("OAuth oauth_consumer_key="):
            self._send(401, {"error": "unauthorized"})
            return False
        return True

    def _fault(self, path):
        """Answer with the fault file's code when its line names this request
        (see the module's docstring); True when it did. Read on every request,
        so a check writes the line between two commands and restarts nothing.
        The count goes back to the file, not to memory, because the check
        reads it: a file still there after a POST is the proof that the
        adapter made one attempt and no more."""
        name = os.environ.get("MOCK_FAULT_FILE")
        if not name or not os.path.exists(name):
            return False
        try:
            parts = open(name).read().split()
            code, count = int(parts[0]), int(parts[1])
            sub = parts[2] if len(parts) > 2 else ""
        except (IndexError, ValueError, OSError):
            return False
        if count <= 0:
            os.remove(name)
            return False
        if sub not in path:
            return False
        # The request's body first: a connection closed with the body unread
        # is a reset to curl, not the status the fault is about.
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        count -= 1
        if count > 0:
            open(name, "w").write(" ".join([str(code), str(count)] + ([sub] if sub else [])) + "\n")
        else:
            os.remove(name)
        data = json.dumps({"error": f"the mock was told to answer {code}"}).encode()
        self.send_response(code)
        if code == 429:
            self.send_header("Retry-After", "0")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        return True

    def _route(self, method):
        path = urlparse(self.path).path
        STATE["log"].append(f"{method} {path}")
        if path == "/_state":
            return self._send(200, STATE)
        if path in ("/_fail/comments/on", "/_fail/comments/off"):
            STATE["fail_comments"] = path.endswith("/on")
            return self._send(200, {"fail_comments": STATE["fail_comments"]})
        if path in ("/_desc/limit/on", "/_desc/limit/off"):
            STATE["desc_limit"] = path.endswith("/on")
            return self._send(200, {"desc_limit": STATE["desc_limit"]})
        if self._fault(self.path):
            return None
        if not self._auth():
            return None
        p = self._params()
        m = re.match(r"^/1/boards/([^/]+)/lists$", path)
        if m and method == "GET":
            return self._send(200, [l for l in STATE["lists"].values() if l["idBoard"] == m.group(1)])
        m = re.match(r"^/1/boards/([^/]+)/cards$", path)
        if m and method == "GET":
            return self._send(200, [self._card(c) for c in STATE["cards"].values()
                                    if STATE["lists"].get(c["idList"], {}).get("idBoard") == m.group(1)])
        m = re.match(r"^/1/boards/([^/]+)/labels$", path)
        if m and method == "GET":
            return self._send(200, list(STATE["labels"].values()))
        m = re.match(r"^/1/boards/([^/]+)$", path)
        if m and method == "GET":
            return self._send(200, {"id": m.group(1), "name": "Mock", "url": f"https://trello.com/b/{m.group(1)}"})
        if path == "/1/lists" and method == "POST":
            lid = new_id("l")
            STATE["lists"][lid] = {"id": lid, "name": p.get("name", ""), "idBoard": p.get("idBoard", BOARD),
                                   "pos": STATE["seq"] * 1000, "closed": False}
            return self._send(200, STATE["lists"][lid])
        m = re.match(r"^/1/lists/([^/]+)/cards$", path)
        if m and method == "GET":
            return self._send(200, sorted([self._card(c) for c in STATE["cards"].values() if c["idList"] == m.group(1)],
                                          key=lambda c: c["pos"]))
        m = re.match(r"^/1/lists/([^/]+)$", path)
        if m and method == "GET":
            l = STATE["lists"].get(m.group(1))
            return self._send(200, l) if l else self._send(404, {"error": "no list"})
        if path == "/1/cards" and method == "POST":
            # A description over Trello's 16384 characters is refused with a
            # 400, as the board refused a reworked ticket (docs/DEFECTS.md
            # 10.2). aif counts before sending; this is what it is counting for.
            if STATE.get("desc_limit", True) and len(p.get("desc", "").encode("utf-16-le")) // 2 > 16384:
                return self._send(400, {"error": "invalid value for desc"})
            cid = new_id("c")
            STATE["cards"][cid] = {"id": cid, "name": p.get("name", ""), "desc": p.get("desc", ""),
                                   "idList": p.get("idList", ""), "pos": self._pos(p.get("pos", "bottom"), p.get("idList", "")),
                                   "idLabels": [], "shortUrl": f"https://trello.com/c/{cid}",
                                   "dateLastActivity": "2026-09-17T00:00:00.000Z"}
            return self._send(200, self._card(STATE["cards"][cid]))
        if path == "/1/labels" and method == "POST":
            lid = new_id("lb")
            STATE["labels"][lid] = {"id": lid, "name": p.get("name", ""), "color": p.get("color"), "idBoard": p.get("idBoard", BOARD)}
            return self._send(200, STATE["labels"][lid])
        m = re.match(r"^/1/cards/([^/]+)/actions/comments$", path)
        if m and method == "POST":
            if STATE.get("fail_comments"):
                return self._send(503, {"error": "the mock was told to refuse comments"})
            try:
                text = parse_qs(self._raw, keep_blank_values=True, errors="strict").get("text", [""])[0]
            except UnicodeDecodeError:
                return self._send(400, {"error": "invalid value for text"})
            if not 1 <= len(text.encode("utf-16-le")) // 2 <= 16384:
                return self._send(400, {"error": "invalid value for text"})
            STATE["comments"].setdefault(m.group(1), []).append(
                {"id": new_id("a"), "date": "2026-09-17T00:00:00.000Z", "data": {"text": p.get("text", "")},
                 "memberCreator": {"username": "mock", "fullName": "Mock User"}})
            return self._send(200, STATE["comments"][m.group(1)][-1])
        m = re.match(r"^/1/cards/([^/]+)/actions$", path)
        if m and method == "GET":
            return self._send(200, list(reversed(STATE["comments"].get(m.group(1), []))))
        m = re.match(r"^/1/cards/([^/]+)/idLabels$", path)
        if m and method == "POST":
            c = STATE["cards"].get(m.group(1))
            if not c:
                return self._send(404, {"error": "no card"})
            if p.get("value") not in c["idLabels"]:
                c["idLabels"].append(p.get("value"))
            return self._send(200, c["idLabels"])
        m = re.match(r"^/1/cards/([^/]+)$", path)
        if m:
            c = STATE["cards"].get(m.group(1))
            if not c:
                return self._send(404, {"error": "no card"})
            if method == "GET":
                return self._send(200, self._card(c))
            if method == "PUT":
                if STATE.get("desc_limit", True) and len(p.get("desc", "").encode("utf-16-le")) // 2 > 16384:
                    return self._send(400, {"error": "invalid value for desc"})
                for k in ("name", "desc", "idList"):
                    if k in p:
                        c[k] = p[k]
                if "pos" in p:
                    c["pos"] = self._pos(p["pos"], c["idList"])
                return self._send(200, self._card(c))
        return self._send(404, {"error": f"no route for {method} {path}"})

    def _pos(self, pos, lid):
        peers = [c["pos"] for c in STATE["cards"].values() if c["idList"] == lid]
        if pos == "top":
            return (min(peers) - 1) if peers else 1000
        if pos == "bottom":
            return (max(peers) + 1000) if peers else 1000
        try:
            return float(pos)
        except ValueError:
            return 1000

    def _card(self, c):
        out = dict(c)
        out["labels"] = [STATE["labels"][l] for l in c["idLabels"] if l in STATE["labels"]]
        return out

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def do_PUT(self):
        self._route("PUT")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    srv = HTTPServer(("127.0.0.1", port), Handler)
    print(srv.server_address[1], flush=True)
    srv.serve_forever()
