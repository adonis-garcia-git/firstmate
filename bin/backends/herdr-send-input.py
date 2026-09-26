#!/usr/bin/env python3
"""Type text into one Herdr pane through Herdr's paste-aware input path.

This helper is the wire transport for fm_backend_herdr_send_composer_text
(bin/backends/herdr.sh). It sends exactly one ``pane.send_input`` request
carrying the text read from stdin and no keys, so nothing is submitted.
Herdr encodes that text server-side with the pane's live bracketed-paste mode:
wrapped in ESC[200~ ... ESC[201~ when the pane's application enabled
bracketed paste, raw bytes otherwise - the same encoding `herdr pane run` and
`herdr agent prompt` use. The CLI's `pane send-text` always writes raw bytes
and offers no text-only form of this method, which is why a raw socket
request is needed here.

Wire protocol verified against Herdr 0.9.1, and the method, its optional
``keys`` field, and its bracketed-paste encoding are identical in the Herdr
0.7.4 source (newline-delimited JSON):

  request:  {"id":"fm-send-input","method":"pane.send_input",
             "params":{"pane_id":P,"text":T}}\n
  response: {"id":"fm-send-input","result":{"type":"ok"}}\n

Usage: herdr-send-input.py <socket_path> <pane_id>   (text on stdin)

Exit status:
  0  the server accepted the text;
  2  arguments, stdin, or the socket connection were invalid;
  3  the request could not be sent or its response could not be read;
  4  the response was malformed, mismatched, or reported an error.
"""

import json
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 10.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 1024 * 1024
REQUEST_ID = "fm-send-input"


def _read_line(sock, deadline):
    buffer = b""
    while b"\n" not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except (OSError, socket.timeout):
            return None
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) > MAX_RESPONSE_BYTES:
            return None
    return buffer.split(b"\n", 1)[0]


def main(argv):
    if len(argv) != 3:
        return 2
    socket_path, pane_id = argv[1:]
    if not socket_path.startswith("/") or not pane_id:
        return 2
    if any(char in pane_id for char in "\t\r\n"):
        return 2
    try:
        text = sys.stdin.buffer.read().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return 2
    if not text:
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(socket_path)
    except OSError:
        return 2

    request = {
        "id": REQUEST_ID,
        "method": "pane.send_input",
        "params": {"pane_id": pane_id, "text": text},
    }
    try:
        sock.sendall(
            (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        )
    except OSError:
        return 3

    line = _read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    if line is None:
        return 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 4
    if not isinstance(response, dict):
        return 4
    result = response.get("result")
    if (
        response.get("id") != REQUEST_ID
        or response.get("error") is not None
        or not isinstance(result, dict)
        or result.get("type") != "ok"
    ):
        return 4
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
