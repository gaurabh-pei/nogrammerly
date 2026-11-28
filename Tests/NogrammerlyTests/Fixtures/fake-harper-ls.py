#!/usr/bin/env python3
"""A scripted stand-in for harper-ls, so timing-dependent behavior can be tested deterministically.

Speaks just enough LSP over stdio: flags every "teh" with a `The` diagnostic and offers "the" as the fix.
Usage: fake-harper-ls.py MODE --stdio
  normal        answer everything at once
  slow-init     wait 1.5 s before answering `initialize`
  late-publish  hold back the diagnostics of a document containing WITHHOLD until the next document is
                opened, then send them (for the old URI) just before that document's own diagnostics
  slow-actions  answer code-action requests for the first document containing SLOW after 1.5 s
  hold PATH     hold back the diagnostics of every document containing HOLD until the file PATH exists;
                creates PATH.seen when such a document arrives, so a test knows the request is outstanding
"""
import os
import json
import sys
import threading
import time

MODE = sys.argv[1] if len(sys.argv) > 1 else "normal"
RELEASE = sys.argv[2] if MODE == "hold" else None
out = sys.stdout.buffer
out_lock = threading.Lock()


def send(message):
    body = json.dumps(message).encode()
    with out_lock:
        out.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        out.flush()


def read():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    return json.loads(sys.stdin.buffer.read(length))


def utf16(text, index):
    return len(text[:index].encode("utf-16-le")) // 2


def diagnostics(text):
    found, start = [], text.find("teh")
    while start != -1:
        line = text.count("\n", 0, start)
        line_start = text.rfind("\n", 0, start) + 1
        character = utf16(text[line_start:], start - line_start)
        found.append({"code": "The", "message": "Did you mean the definite article?", "severity": 4, "source": "Harper",
                      "range": {"start": {"line": line, "character": character},
                                "end": {"line": line, "character": character + 3}}})
        start = text.find("teh", start + 1)
    return found


def publish(uri, text):
    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
          "params": {"uri": uri, "diagnostics": diagnostics(text)}})


def actions(uri, diagnostic):
    return [{"title": "Replace with: “the”", "kind": "quickfix",
             "edit": {"changes": {uri: [{"range": diagnostic["range"], "newText": "the"}]}}},
            {"title": "Ignore Harper error.", "command": "HarperIgnoreLint",
             "arguments": [uri, {"lint_kind": "Miscellaneous", "message": diagnostic["message"]}]}]


withheld = None
texts = {}
slowed = set()
while True:
    message = read()
    if message is None:
        break
    method, params = message.get("method"), message.get("params") or {}
    if method == "initialize":
        if MODE == "slow-init":
            time.sleep(1.5)
        send({"jsonrpc": "2.0", "id": message["id"],
              "result": {"capabilities": {"codeActionProvider": True, "textDocumentSync": 1}}})
    elif method == "textDocument/didOpen":
        document = params["textDocument"]
        texts[document["uri"]] = document["text"]
        if withheld:
            publish(*withheld)
            withheld = None
        if MODE == "late-publish" and "WITHHOLD" in document["text"]:
            withheld = (document["uri"], document["text"])
        elif MODE == "hold" and "HOLD" in document["text"]:
            open(RELEASE + ".seen", "w").close()

            def release_later(uri=document["uri"], text=document["text"]):
                while not os.path.exists(RELEASE):
                    time.sleep(0.01)
                publish(uri, text)
            threading.Thread(target=release_later, daemon=True).start()
        else:
            publish(document["uri"], document["text"])
    elif method == "textDocument/codeAction":
        reply = {"jsonrpc": "2.0", "id": message["id"],
                 "result": [a for d in params["context"]["diagnostics"] for a in actions(params["textDocument"]["uri"], d)]}
        uri = params["textDocument"]["uri"]
        if MODE == "slow-actions" and "SLOW" in texts.get(uri, "") and (not slowed or uri in slowed):
            slowed.add(uri)
            threading.Timer(1.5, send, args=(reply,)).start()
        else:
            send(reply)
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
    elif method == "exit":
        break
    elif "id" in message:
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
