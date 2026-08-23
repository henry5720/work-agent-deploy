#!/usr/bin/env python3
"""company provider 的 request route 回歸測試。

擋的是一個已經在 production 咬過的 bug：`config/opencode/opencode.json` 把
`provider.company.npm` 寫成 `@ai-sdk/openai-compatible`，於是 OpenCode 把推論打到
`{baseURL}/chat/completions`，公司 gateway 回 HTTP 405。那個 gateway 只提供
Responses API —— `agents/bin/company-image` 一直都是打 `{baseURL}/responses`
（見 docs/adr/0008-restricted-company-image-cli.md）。

OpenCode 依 `npm` 欄位決定呼叫 SDK 的哪個 factory，factory 決定 URL 後綴。這裡把
那段對應關係寫成表並跑一次，所以「換掉 adapter 名字」會在 CI 就爆，不必等 Slack
上再回一次 405。

**這份不能證明公司 gateway 接受請求。** 它沒有開 socket、沒有 key、沒有裝
`@ai-sdk/*`。它證明的是：repo 裡選的 adapter 會被 OpenCode 路到 Responses API，
而且跟 `company-image` 對 `COMPANY_GATEWAY_BASE_URL` 的解讀一致。真的往返仍然
只有 `docs/runbook.md`「人工 release gate」能驗。
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "config/opencode/opencode.json"
IMAGE_CLI = ROOT / "agents/bin/company-image"

# 假的 base URL。刻意不帶 /v1，因為公司 gateway 的 Responses API 不掛在 /v1 底下；
# 這個測試只在意「後綴接了什麼」，不在意前綴長什麼樣。
FAKE_BASE_URL = "https://gateway.example.invalid/backend-api/codex"

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    if not ok:
        failures.append(f"{label}{f' ({detail})' if detail else ''}")


# --------------------------------------------------------------------------
# OpenCode 對 npm adapter 的處理，抄自安裝好的 opencode binary。
#
# 每個 npm 套件的 `createX(options)` 回傳的 provider instance 身上有哪些 factory：
#   @ai-sdk/openai            -> languageModel / chat / completion / responses / ...
#   @ai-sdk/openai-compatible -> languageModel / chatModel / completionModel / ...
#     （沒有 `responses`，也沒有 `chat`）
#
# 以及每個 factory 會把請求打到 baseURL 底下的哪個路徑。
# --------------------------------------------------------------------------
ADAPTERS = {
    "@ai-sdk/openai": {
        "surface": ("languageModel", "chat", "completion", "responses"),
        "options": ("baseURL", "apiKey", "organization", "project", "name", "headers"),
    },
    "@ai-sdk/openai-compatible": {
        "surface": ("languageModel", "chatModel", "completionModel"),
        "options": ("baseURL", "apiKey", "name", "headers"),
    },
}

FACTORY_PATH = {
    "responses": "/responses",
    "messages": "/messages",
    "chat": "/chat/completions",
    # openai-compatible 的預設 factory 就是 chat completions。
    "languageModel": "/chat/completions",
}


def resolve_factory(surface: tuple[str, ...], force_chat: bool = False) -> str:
    """OpenCode 挑 factory 的順序。

    binary 裡長這樣：
        if (forceChat && sdk.chat) return sdk.chat(id)
        if (sdk.responses)         return sdk.responses(id)
        if (sdk.messages)          return sdk.messages(id)
        if (sdk.chat)              return sdk.chat(id)
        return sdk.languageModel(id)
    """
    if force_chat and "chat" in surface:
        return "chat"
    for factory in ("responses", "messages", "chat"):
        if factory in surface:
            return factory
    return "languageModel"


def endpoint_for(npm: str, base_url: str) -> str:
    adapter = ADAPTERS[npm]
    factory = resolve_factory(adapter["surface"])
    return base_url.rstrip("/") + FACTORY_PATH[factory]


def load_image_cli():
    # agents/bin/ 是要 COPY 進 image 的東西，不要在裡面留下 __pycache__。
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_loader(
        "company_image",
        importlib.machinery.SourceFileLoader("company_image", str(IMAGE_CLI)),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    config = json.loads(CONFIG.read_text())
    company = config["provider"]["company"]
    npm = company.get("npm")

    # ---------------------------------------------------- adapter 名字本身
    check(
        "provider.company.npm is a known adapter",
        npm in ADAPTERS,
        f"npm={npm!r}; 這份測試沒有它的 route 對應表，先補表再改設定",
    )
    if npm not in ADAPTERS:
        # 對應表都沒有，後面每一項都會是雜訊。
        print("provider-route: unknown adapter, cannot derive a route", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    check(
        "provider.company.npm is @ai-sdk/openai",
        npm == "@ai-sdk/openai",
        f"npm={npm!r}; 公司 gateway 只有 Responses API",
    )

    # ---------------------------------------------------- 路由結果
    route = endpoint_for(npm, FAKE_BASE_URL)
    check(
        "the company provider routes to the Responses API",
        route == FAKE_BASE_URL + "/responses",
        f"route={route}",
    )

    # 反向釘住那個 bug：openai-compatible 一定會打到 chat completions。表要是被
    # 改成「兩個都算 responses」，這裡會先失敗。
    regression = endpoint_for("@ai-sdk/openai-compatible", FAKE_BASE_URL)
    check(
        "openai-compatible still routes to /chat/completions (the HTTP 405 bug)",
        regression == FAKE_BASE_URL + "/chat/completions",
        f"route={regression}",
    )

    # ------------------------------------- 跟 company-image 對同一個 env 的解讀
    # 兩邊吃的是同一個 COMPANY_GATEWAY_BASE_URL。如果兩邊接的後綴不一樣，
    # 那個 env 就沒有一個能同時滿足生圖與推論的值。
    cli = load_image_cli()
    saved = os.environ.get("COMPANY_GATEWAY_BASE_URL")
    os.environ["COMPANY_GATEWAY_BASE_URL"] = FAKE_BASE_URL
    try:
        image_endpoint = cli.gateway_endpoint()
    finally:
        if saved is None:
            os.environ.pop("COMPANY_GATEWAY_BASE_URL", None)
        else:
            os.environ["COMPANY_GATEWAY_BASE_URL"] = saved

    check(
        "company-image and the OpenCode provider agree on the base URL suffix",
        image_endpoint == route,
        f"company-image={image_endpoint} provider={route}",
    )

    # ---------------------------------------------------- options 沒有漂掉
    # createOpenAI 與 createOpenAICompatible 的 baseURL/apiKey 同名，所以換 adapter
    # 不需要改 options。這裡確認設定沒有用到只有舊 adapter 認得的 key。
    options = company["options"]
    unknown = sorted(set(options) - set(ADAPTERS[npm]["options"]))
    check(
        "provider.company.options only uses keys this adapter accepts",
        not unknown,
        f"unknown={unknown}",
    )
    check(
        "baseURL stays an env reference",
        options.get("baseURL") == "{env:COMPANY_GATEWAY_BASE_URL}",
        f"baseURL={options.get('baseURL')!r}",
    )
    check(
        "apiKey stays an env reference",
        options.get("apiKey") == "{env:COMPANY_GATEWAY_API_KEY}",
        "apiKey is not the {env:...} placeholder",
    )

    # 換 adapter 不准動 model ID。gateway 認的是這兩個字串。
    check(
        "the model IDs are unchanged",
        set(company["models"]) == {"gpt-5.6-terra", "gpt-5.6-luna"},
        f"models={sorted(company['models'])}",
    )

    if failures:
        print(f"provider-route: {len(failures)} check(s) failed", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        "Provider route checks passed (adapter table only; no gateway call was made)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
