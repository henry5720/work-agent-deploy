#!/usr/bin/env python3
"""受限 Slack artifact uploader 的離線契約測試；不會開 socket。"""
from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "agents/bin/slack-thread-artifact"
TOKEN = "test-token-not-a-secret"
failures: list[str] = []


def check(name, condition, detail=""):
    if not condition:
        failures.append(f"{name}: {detail}" if detail else name)


def load():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_loader("slack_artifact", importlib.machinery.SourceFileLoader("slack_artifact", str(CLI)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Response:
    def __init__(self, payload=b'{"ok": true}', status=200): self.payload, self.status = payload, status
    def read(self): return self.payload
    def __enter__(self): return self
    def __exit__(self, *_): return False


class Slack:
    def __init__(self, fail_at=None): self.requests, self.fail_at = [], fail_at
    def __call__(self, request, timeout=None):
        self.requests.append(request)
        index = len(self.requests)
        if self.fail_at == index: raise OSError("mock failure")
        if index == 1: return Response(json.dumps({"ok": True, "upload_url": "https://uploads.slack.test/upload", "file_id": "F123"}).encode())
        return Response()


def run(cli, argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try: code = cli.main(argv)
        except SystemExit as exc: code = exc.code if isinstance(exc.code, int) else 1
    return code, out.getvalue(), err.getvalue()


def main():
    cli = load(); root = Path(tempfile.mkdtemp(prefix="slack-artifact-test-"))
    try:
        cli.DRAFTS_ROOT = root / "drafts"; cli.DRAFTS_ROOT.mkdir()
        os.environ["SLACK_BOT_TOKEN"] = TOKEN
        artifact = cli.DRAFTS_ROOT / "image.png"; artifact.write_bytes(b"\x89PNG\r\n\x1a\nmock")
        fake = Slack(); cli.urlopen = fake
        code, _, err = run(cli, ["--file", str(artifact), "--channel", "C0123456789", "--thread-ts", "1710000000.123456"])
        check("happy path exits 0", code == 0, err)
        check("successful upload deletes draft", not artifact.exists())
        check("three fixed requests", len(fake.requests) == 3)
        if len(fake.requests) == 3:
            first, second, third = fake.requests
            check("gets Slack upload ticket", first.full_url.endswith("/files.getUploadURLExternal"))
            check("ticket body has name and length only", set(json.loads(first.data)) == {"filename", "length"})
            check("upload uses ticket URL", second.full_url == "https://uploads.slack.test/upload")
            check("complete upload endpoint", third.full_url.endswith("/files.completeUploadExternal"))
            body = json.loads(third.data)
            check("complete binds original channel/thread", body["channel_id"] == "C0123456789" and body["thread_ts"] == "1710000000.123456")
        for fail_at in (1, 2, 3):
            candidate = cli.DRAFTS_ROOT / f"failure-{fail_at}.md"; candidate.write_text("# draft")
            fake = Slack(fail_at); cli.urlopen = fake
            code, _, err = run(cli, ["--file", str(candidate), "--channel", "C0123456789", "--thread-ts", "1710000000.1"])
            check(f"failure {fail_at} exits runtime", code == cli.EXIT_RUNTIME, err)
            check(f"failure {fail_at} keeps draft", candidate.exists())
            check(f"failure {fail_at} never leaks token", TOKEN not in err)
        outside = root / "outside.png"; outside.write_bytes(b"\x89PNG\r\n\x1a\n")
        bad = [
            ("outside", ["--file", str(outside), "--channel", "C0123456789", "--thread-ts", "1710000000.1"]),
            ("wrong extension", ["--file", str(cli.DRAFTS_ROOT / "bad.txt"), "--channel", "C0123456789", "--thread-ts", "1710000000.1"]),
            ("bad channel", ["--file", str(cli.DRAFTS_ROOT / "failure-1.md"), "--channel", "https://evil", "--thread-ts", "1710000000.1"]),
            ("bad thread", ["--file", str(cli.DRAFTS_ROOT / "failure-1.md"), "--channel", "C0123456789", "--thread-ts", "evil"]),
            ("no url option", ["--file", str(cli.DRAFTS_ROOT / "failure-1.md"), "--channel", "C0123456789", "--thread-ts", "1710000000.1", "--url", "https://evil"]),
        ]
        (cli.DRAFTS_ROOT / "bad.txt").write_text("x")
        for name, argv in bad:
            fake = Slack(); cli.urlopen = fake; code, _, _ = run(cli, argv)
            check(f"rejects {name}", code != 0)
            check(f"rejects {name} before network", not fake.requests)
    finally: shutil.rmtree(root, ignore_errors=True)
    if failures:
        print("slack-thread-artifact: failed", *failures, sep="\n  - ", file=sys.stderr); return 1
    print("Slack artifact checks passed (mocked Slack; no real call was made)."); return 0


if __name__ == "__main__": sys.exit(main())
