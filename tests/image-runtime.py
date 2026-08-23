#!/usr/bin/env python3
"""agents/bin/company-image 的 mockable 測試。

不連網、不需要 Docker、不需要真的 gateway key：`urlopen` 被換成一個會把
`Request` 收下來的假物件，所以測得到「送出去的請求長什麼樣」。輸出目錄與允許的
來源目錄也被指到 tmpdir，production 那份因此不必為了測試多開任何覆蓋參數。

這份測的是 CLI 契約：請求 shape、PNG 輸出位置、以及不合法輸入一定被擋。它不能
證明公司 gateway 真的接受這個 shape —— 那要在有 key 的環境實打一次。
"""

from __future__ import annotations

import base64
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import struct
import sys
import tempfile
import zlib
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "agents/bin/company-image"

FAKE_KEY = "test-key-not-a-real-secret"
FAKE_BASE_URL = "https://gateway.example.invalid/v1"

failures: list[str] = []


def load_cli():
    # agents/bin/ 是要 COPY 進 image 的東西，不要在裡面留下 __pycache__。
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_loader(
        "company_image", importlib.machinery.SourceFileLoader("company_image", str(CLI))
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def png_bytes(width: int = 1, height: int = 1) -> bytes:
    """最小的合法 PNG，用來當假 gateway 的回傳與 edit 的來源圖。"""

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + b"\x00\x00\x00" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


class FakeResponse:
    def __init__(self, payload: bytes):
        self._payload = payload

    def read(self) -> bytes:
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeGateway:
    """收下 Request 並回一個固定的 Responses payload。"""

    def __init__(self, payload=None, image: bytes | None = None):
        self.requests = []
        self.timeouts = []
        if payload is None:
            encoded = base64.b64encode(image if image is not None else png_bytes()).decode()
            payload = {
                "output": [
                    {"type": "reasoning", "summary": []},
                    {"type": "image_generation_call", "result": encoded},
                ]
            }
        self.payload = payload

    def __call__(self, request, timeout=None):
        self.requests.append(request)
        self.timeouts.append(timeout)
        return FakeResponse(json.dumps(self.payload).encode())

    @property
    def body(self) -> dict:
        return json.loads(self.requests[-1].data.decode())


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        return
    failures.append(f"{name}{': ' + detail if detail else ''}")


def run(cli, argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = cli.main(argv)
        except SystemExit as exc:  # argparse rejects unknown modes and sizes itself
            code = exc.code if isinstance(exc.code, int) else 1
    return code, out.getvalue(), err.getvalue()


def today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def main() -> int:
    cli = load_cli()
    workdir = Path(tempfile.mkdtemp(prefix="company-image-test-"))
    try:
        drafts = workdir / "drafts"
        staging = workdir / "staging"
        outside = workdir / "outside"
        for directory in (drafts, staging, outside):
            directory.mkdir()

        cli.DRAFTS_ROOT = drafts
        cli.SOURCE_ROOTS = (drafts, staging)
        os.environ["COMPANY_GATEWAY_BASE_URL"] = FAKE_BASE_URL
        os.environ["COMPANY_GATEWAY_API_KEY"] = FAKE_KEY

        # ------------------------------------------------ generate happy path
        gateway = FakeGateway()
        cli.urlopen = gateway
        code, out, err = run(
            cli, ["generate", "--prompt", "  a red square  ", "--name", "hero"]
        )
        check("generate exits 0", code == 0, f"code={code} stderr={err.strip()}")
        check("generate calls the gateway once", len(gateway.requests) == 1)

        if gateway.requests:
            request = gateway.requests[0]
            check(
                "endpoint is base URL + /responses",
                request.full_url == "https://gateway.example.invalid/v1/responses",
                request.full_url,
            )
            check("method is POST", request.get_method() == "POST")
            check(
                "Authorization header carries the env key",
                request.get_header("Authorization") == f"Bearer {FAKE_KEY}",
            )
            check(
                "Content-Type is JSON",
                request.get_header("Content-type") == "application/json",
            )
            check(
                "only the two fixed headers are sent",
                {k.lower() for k in request.headers} == {"authorization", "content-type"},
                str(sorted(request.headers)),
            )
            check("timeout is set", gateway.timeouts[0] == cli.REQUEST_TIMEOUT_SECONDS)

            body = gateway.body
            check("model is the pinned one", body["model"] == cli.MODEL, body["model"])
            check(
                "image_generation tool is requested",
                body["tools"] == [
                    {
                        "type": "image_generation",
                        "size": "1024x1024",
                        "output_format": "png",
                    }
                ],
                json.dumps(body["tools"]),
            )
            check(
                "the tool is forced",
                body["tool_choice"] == {"type": "image_generation"},
            )
            content = body["input"][0]["content"]
            check(
                "prompt is sent trimmed as input_text",
                content == [{"type": "input_text", "text": "a red square"}],
                json.dumps(content),
            )
            check("generate sends no input_image", all(c["type"] != "input_image" for c in content))

        written = drafts / today() / "hero.png"
        check("PNG lands in drafts", written.is_file(), str(written))
        if written.is_file():
            check("output is a real PNG", written.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))
        check("stdout is exactly the output path", out.strip() == str(written), out.strip())

        # --------------------------------------------------- name collision
        gateway = FakeGateway()
        cli.urlopen = gateway
        code, out, _ = run(cli, ["generate", "--prompt", "again", "--name", "hero"])
        check("second run exits 0", code == 0)
        check(
            "a colliding name does not overwrite",
            out.strip() == str(drafts / today() / "hero-2.png"),
            out.strip(),
        )

        # ---------------------------------------------------- edit happy path
        source = staging / "shot.png"
        source_bytes = png_bytes(2, 2)
        source.write_bytes(source_bytes)
        gateway = FakeGateway()
        cli.urlopen = gateway
        code, out, err = run(
            cli,
            [
                "edit",
                "--prompt",
                "make it blue",
                "--name",
                "edited",
                "--size",
                "1536x1024",
                "--source",
                str(source),
            ],
        )
        check("edit exits 0", code == 0, f"code={code} stderr={err.strip()}")
        if gateway.requests:
            content = gateway.body["input"][0]["content"]
            check("edit sends text first", content[0]["type"] == "input_text")
            check("edit attaches one input_image", len(content) == 2 and content[1]["type"] == "input_image")
            if len(content) == 2:
                expected = "data:image/png;base64," + base64.b64encode(source_bytes).decode()
                check("input_image is the source as a data URL", content[1]["image_url"] == expected)
            check(
                "size is passed through from the allowlist",
                gateway.body["tools"][0]["size"] == "1536x1024",
            )
        check("edit writes a PNG", (drafts / today() / "edited.png").is_file())

        # ------------------------------------------------------ bad input
        rejected = [
            (
                "unknown mode",
                ["upscale", "--prompt", "x", "--name", "a"],
            ),
            (
                "size outside the allowlist",
                ["generate", "--prompt", "x", "--name", "a", "--size", "4096x4096"],
            ),
            (
                "name with a path separator",
                ["generate", "--prompt", "x", "--name", "../escape"],
            ),
            (
                "name with an extension",
                ["generate", "--prompt", "x", "--name", "a.png"],
            ),
            (
                "empty prompt",
                ["generate", "--prompt", "   ", "--name", "a"],
            ),
            (
                "prompt over the cap",
                ["generate", "--prompt", "x" * (cli.MAX_PROMPT_CHARS + 1), "--name", "a"],
            ),
            (
                "generate does not take --source",
                ["generate", "--prompt", "x", "--name", "a", "--source", str(source)],
            ),
            (
                "edit without --source",
                ["edit", "--prompt", "x", "--name", "a"],
            ),
            (
                "source outside the allowed roots",
                ["edit", "--prompt", "x", "--name", "a", "--source", str(outside / "x.png")],
            ),
            (
                "relative source",
                ["edit", "--prompt", "x", "--name", "a", "--source", "shot.png"],
            ),
            (
                "there is no --url flag",
                ["generate", "--prompt", "x", "--name", "a", "--url", "https://evil.invalid"],
            ),
            (
                "there is no --header flag",
                ["generate", "--prompt", "x", "--name", "a", "--header", "X: 1"],
            ),
            (
                "there is no --model flag",
                ["generate", "--prompt", "x", "--name", "a", "--model", "other"],
            ),
            (
                "there is no --output flag",
                ["generate", "--prompt", "x", "--name", "a", "--output", "/etc/x.png"],
            ),
        ]
        (outside / "x.png").write_bytes(png_bytes())
        for label, argv in rejected:
            gateway = FakeGateway()
            cli.urlopen = gateway
            before = sorted(p.name for p in (drafts / today()).glob("*"))
            code, out, err = run(cli, argv)
            check(f"rejects: {label}", code != 0, f"exit={code}")
            check(f"rejects without calling the gateway: {label}", not gateway.requests)
            after = sorted(p.name for p in (drafts / today()).glob("*"))
            check(f"rejects without writing a file: {label}", before == after)

        # A file that exists in an allowed root but is not an image.
        not_an_image = staging / "notes.txt"
        not_an_image.write_text("plain text")
        gateway = FakeGateway()
        cli.urlopen = gateway
        code, _, _ = run(
            cli, ["edit", "--prompt", "x", "--name", "a", "--source", str(not_an_image)]
        )
        check("rejects a non-image source", code == cli.EXIT_INVALID_INPUT, f"exit={code}")
        check("non-image source never reaches the gateway", not gateway.requests)

        # A symlink in an allowed root that points outside it.
        escape = staging / "escape.png"
        escape.symlink_to(outside / "x.png")
        gateway = FakeGateway()
        cli.urlopen = gateway
        code, _, _ = run(cli, ["edit", "--prompt", "x", "--name", "a", "--source", str(escape)])
        check("rejects a symlink that escapes the allowed roots", code == cli.EXIT_INVALID_INPUT)
        check("escaping symlink never reaches the gateway", not gateway.requests)

        # ------------------------------------------------------ bad gateway
        for label, payload in (
            ("no image_generation_call", {"output": [{"type": "message"}]}),
            ("no output array", {"error": "nope"}),
            ("result is not base64", {"output": [{"type": "image_generation_call", "result": "!!!"}]}),
            (
                "result is not a PNG",
                {
                    "output": [
                        {
                            "type": "image_generation_call",
                            "result": base64.b64encode(b"GIF89a nope").decode(),
                        }
                    ]
                },
            ),
        ):
            cli.urlopen = FakeGateway(payload=payload)
            code, _, err = run(cli, ["generate", "--prompt", "x", "--name", "bad"])
            check(f"gateway failure exits 3: {label}", code == cli.EXIT_RUNTIME, f"exit={code}")
            check(f"gateway failure writes nothing: {label}", not (drafts / today() / "bad.png").exists())
            check(f"the key never leaks into stderr: {label}", FAKE_KEY not in err)

        # ------------------------------------------------------ bad env
        cli.urlopen = FakeGateway()
        for label, env, expected in (
            ("missing key", {"COMPANY_GATEWAY_API_KEY": ""}, cli.EXIT_RUNTIME),
            ("placeholder key", {"COMPANY_GATEWAY_API_KEY": "replace-me"}, cli.EXIT_RUNTIME),
            ("missing base URL", {"COMPANY_GATEWAY_BASE_URL": ""}, cli.EXIT_RUNTIME),
            (
                "plain http base URL",
                {"COMPANY_GATEWAY_BASE_URL": "http://gateway.example.invalid/v1"},
                cli.EXIT_RUNTIME,
            ),
            (
                "non-http base URL",
                {"COMPANY_GATEWAY_BASE_URL": "file:///etc/passwd"},
                cli.EXIT_RUNTIME,
            ),
        ):
            saved = {k: os.environ.get(k) for k in env}
            os.environ.update(env)
            code, _, err = run(cli, ["generate", "--prompt", "x", "--name", "envcase"])
            check(f"bad env exits 3: {label}", code == expected, f"exit={code}")
            check(f"bad env writes nothing: {label}", not (drafts / today() / "envcase.png").exists())
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

        # localhost over http is the one http case the CLI allows, so the
        # mockable test itself can point at a loopback gateway.
        os.environ["COMPANY_GATEWAY_BASE_URL"] = "http://127.0.0.1:8080/v1"
        gateway = FakeGateway()
        cli.urlopen = gateway
        code, out, err = run(cli, ["generate", "--prompt", "x", "--name", "loopback"])
        check("http on loopback is allowed", code == 0, f"code={code} stderr={err.strip()}")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if failures:
        print(f"image-runtime: {len(failures)} check(s) failed", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("Image runtime checks passed (mocked gateway; no real call was made).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
