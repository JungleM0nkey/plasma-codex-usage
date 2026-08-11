#!/usr/bin/env python3
"""Fetch Codex CLI account rate limits via `codex app-server`'s JSON-RPC stdio protocol.

Speaks the same handshake the codex-tui itself uses (initialize -> initialized ->
account/rateLimits/read), so it stays correct across auth refreshes without
re-implementing OpenAI's backend HTTP contract by hand.
"""
import json
import subprocess
import time

TIMEOUT_SECONDS = 15


def main():
    try:
        proc = subprocess.Popen(
            ["codex", "app-server", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        print(json.dumps({"ok": False, "error": "codex not found"}))
        return

    def send(msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    result = None
    error = None
    try:
        send({
            "id": 1,
            "method": "initialize",
            "params": {"clientInfo": {"name": "kde-codex-usage-widget", "version": "1.0.0"}},
        })
        send({"method": "initialized"})
        send({"id": 2, "method": "account/rateLimits/read", "params": None})

        deadline = time.time() + TIMEOUT_SECONDS
        while time.time() < deadline:
            line = proc.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == 2:
                if "result" in msg:
                    result = msg["result"]
                elif "error" in msg:
                    error = msg["error"].get("message", "unknown error")
                break
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except Exception:
            proc.kill()

    if result is not None:
        print(json.dumps({"ok": True, "data": result}))
    else:
        print(json.dumps({"ok": False, "error": error or "timeout"}))


if __name__ == "__main__":
    main()
