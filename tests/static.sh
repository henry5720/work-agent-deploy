#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# 這支只做靜態檢查。任何需要 Docker、真的 container 或真的 gateway 的事都不在這裡，
# 跑得過不代表 runtime 通過。無法在本機驗證的項目記進 LIMITED，最後一起印出來，
# 不要讓「Static checks passed」被讀成 smoke test 過了。
LIMITED=()
limited() { LIMITED+=("$1"); }

test -f "$ROOT/CONTEXT.md"
test -f "$ROOT/CLAUDE.md"
test -f "$ROOT/Dockerfile"
test -f "$ROOT/.env.example"
test -f "$ROOT/docs/system-design.md"
test -f "$ROOT/config/slack-home.json"
test -f "$ROOT/docs/adr/0001-github-access-stops-at-the-host-boundary.md"
test -f "$ROOT/docs/adr/0002-run-the-deployment-host-inside-restricted-incus.md"
test -f "$ROOT/docs/adr/0003-deploy-directly-on-the-fedora-host.md"
test -f "$ROOT/docs/adr/0004-schedule-snapshots-with-cron.md"
test -f "$ROOT/docs/adr/0006-readonly-product-context-handoff-bot.md"
test -f "$ROOT/docs/adr/0007-single-container-opencode-runtime.md"
test -f "$ROOT/docs/adr/0008-restricted-company-image-cli.md"
test -f "$ROOT/docs/adr/0010-company-provider-uses-the-responses-api.md"
test ! -e "$ROOT/systemd"
test -x "$ROOT/scripts/install-sync-cron.sh"
test -x "$ROOT/scripts/compose.sh"
test -x "$ROOT/agents/bin/company-image"
test -x "$ROOT/agents/bin/slack-thread-artifact"
test -x "$ROOT/tests/image-runtime.py"
test -x "$ROOT/tests/slack-thread-artifact.py"
test -x "$ROOT/tests/artifact-path-safety.py"
test -x "$ROOT/tests/provider-route.py"
test -f "$ROOT/tests/parse-document.py"
test -x "$ROOT/agents/bin/parse-document"
test ! -e "$ROOT/scripts/install-sync-timer.sh"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/managed-claude-settings.json"
python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert v["type"] == "home"; assert v["blocks"]' "$ROOT/config/slack-home.json"
python3 -c 'import sys,tomllib; c=tomllib.load(open(sys.argv[1], "rb")); assert c["slack"]["allow_all_users"] is False; assert len(c["slack"]["allowed_users"]) == 17; assert c["pool"] == {"max_sessions": 10, "session_ttl_hours": 4}; assert "workspace" not in c; assert c["agent"]["working_dir"] == "/home/node/code"' "$ROOT/config/openab.toml"
python3 - "$ROOT" <<'PY'
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
expected_filestore = {
    "bucket": "work-agent-attachments",
    "endpoint": "https://99de68928da234ebcf0c9370443ad7ee.r2.cloudflarestorage.com",
    "region": "auto",
    "prefix": "incoming/",
    "presigned_ttl": 3600,
    "max_file_size_mb": 50,
    "access_key_id": "${R2_ACCESS_KEY_ID}",
    "secret_access_key": "${R2_SECRET_ACCESS_KEY}",
}
configs = [tomllib.loads((root / name).read_text()) for name in (
    "config/openab.toml", "config/openab.claude-acp.toml"
)]
for config in configs:
    assert config["filestore"] == expected_filestore
    assert set(config["filestore"]) == set(expected_filestore)
assert configs[0]["filestore"] == configs[1]["filestore"], "R2 filestore differs between runtimes"
PY

python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
compose = (root / "compose.yaml").read_text()
env_example = (root / "env/openab.env.example").read_text().splitlines()
expected_host = "99de68928da234ebcf0c9370443ad7ee.r2.cloudflarestorage.com"
runtime_environment = {
    "PARSE_DOCUMENT_ALLOWED_HOST": expected_host,
    "DOCLING_ARTIFACTS_PATH": "/opt/docling-models",
}
for key, value in runtime_environment.items():
    assert f"{key}: {value}" in compose, f"compose.yaml does not provide {key}"
    assert f"{key}:" in compose, f"compose.yaml environment source lost {key}"
assert "R2_ACCESS_KEY_ID=" in env_example
assert "R2_SECRET_ACCESS_KEY=" in env_example
assert "R2_ACCESS_KEY_ID=replace-me" not in env_example
assert "R2_SECRET_ACCESS_KEY=replace-me" not in env_example

preflight = (root / "scripts/preflight.sh").read_text()
for required in (
    "R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY",
    "PARSE_DOCUMENT_ALLOWED_HOST",
    "placeholder",
    "require_manual_release_gate",
    "-t 0 && -t 1 && -r /dev/tty",
    "files:read",
    "lifecycle",
    "refusing noninteractive deployment",
):
    assert required in preflight, f"preflight gate lost {required!r}"
assert "curl" not in preflight and "slack api" not in preflight.lower()

deploy = (root / "scripts/deploy.sh").read_text()
assert '"$ROOT/scripts/preflight.sh"' in deploy
assert deploy.index('"$ROOT/scripts/preflight.sh"') < deploy.index("compose build")
assert "interactive gate" in deploy

runtime_docs = (
    "README.md",
    "agents/CLAUDE.md",
    "config/slack-home.json",
    "docs/runbook.md",
    "docs/system-design.md",
    "docs/adr/0007-single-container-opencode-runtime.md",
)
old_refusal = ("PDF、Office", "PDF/DOCX", "尚未支援解析", "單檔上限 250 MB", "250 MB")
for name in runtime_docs:
    text = (root / name).read_text()
    for phrase in old_refusal:
        assert phrase not in text, f"old attachment refusal remains in {name}: {phrase}"
    assert "parse-document <url> <filename>" in text or name == "config/slack-home.json"
    assert "50 MiB" in text, f"{name} omits the 50 MiB attachment limit"
    assert "company gateway" in text, f"{name} omits the presigned URL trust boundary"
PY

grep -q 'WORK_HELPER_ISSUE_MODE=manual' "$ROOT/env/openab.env.example"
grep -q '^\.env$' "$ROOT/.gitignore"
grep -q '^/runtime/$' "$ROOT/.gitignore"
grep -q '^SNAPSHOT_ROOT=${HOME}/work-agent-snapshots$' "$ROOT/.env.example"
grep -q '^HOST_UID=1000$' "$ROOT/.env.example"
grep -q '^HOST_GID=1000$' "$ROOT/.env.example"
grep -Fq 'load_env "$ROOT"' "$ROOT/scripts/preflight.sh"
grep -Fq 'load_versions "$ROOT"' "$ROOT/scripts/preflight.sh"
grep -Fq "value=\${value//'\${HOME}'/\$HOME}" "$ROOT/scripts/lib.sh"
! grep -q -E '^(STATE_ROOT|DRAFT_ROOT)=' "$ROOT/.env.example"
grep -q 'allow_all_users = false' "$ROOT/config/openab.toml"
grep -q 'assistant_mode = false' "$ROOT/config/openab.toml"
grep -q 'CLAUDE_CONFIG_DIR: /home/node/.claude' "$ROOT/compose.yaml"
grep -q './runtime/openab:/home/node/.openab:z' "$ROOT/compose.yaml"
grep -q './runtime/drafts:/home/node/drafts:z' "$ROOT/compose.yaml"
grep -q 'views.publish' "$ROOT/scripts/publish-slack-home.sh"
grep -q 'apt-get install -y --no-install-recommends curl git libglib2.0-0 libgl1 libxcb1 python3 python3-pip' "$ROOT/Dockerfile"
grep -q 'ARG HOST_UID=1000' "$ROOT/Dockerfile"
grep -Fq 'usermod -u "$HOST_UID"' "$ROOT/Dockerfile"
grep -q 'HOST_UID: ${HOST_UID:-1000}' "$ROOT/compose.yaml"
grep -q 'dockerfile: Dockerfile' "$ROOT/compose.yaml"
grep -q 'exec -T backlog-agent python3 --version' "$ROOT/scripts/deploy.sh"
grep -q 'slack-list --help' "$ROOT/scripts/deploy.sh"
grep -q 'test -w /home/node/.openab' "$ROOT/scripts/deploy.sh"
grep -Fq 'must be owned by $HOST_UID:$HOST_GID' "$ROOT/scripts/preflight.sh"
grep -q 'slack-list add' "$ROOT/agents/CLAUDE.md"
grep -q '建立與整理待辦' "$ROOT/config/slack-home.json"
grep -Fq '不要派工、不要接單。' "$ROOT/agents/CLAUDE.md"
grep -Fq 'Claude Code ACP specialist' "$ROOT/agents/CLAUDE.md"
grep -Fq 'claude-credentials' "$ROOT/agents/CLAUDE.md"
grep -Fq 'OMO 可委派' "$ROOT/agents/CLAUDE.md"
grep -Fq 'git show origin/<branch>:<path>' "$ROOT/agents/CLAUDE.md"
grep -Fq '不要 `git checkout` 或 `git switch`' "$ROOT/agents/CLAUDE.md"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["disableClaudeAiConnectors"] is True; assert c["permissions"]["allow"] == ["Bash(company-image *)", "Bash(slack-thread-artifact *)"]' "$ROOT/managed-claude-settings.json"
grep -Fq 'Bash(git checkout*)' "$ROOT/managed-claude-settings.json"
grep -Fq 'Bash(git switch*)' "$ROOT/managed-claude-settings.json"

# ---------------------------------------------------------------- versions
# config/versions.env is the single source for every pinned version. Nothing may
# float, and the two OpenAB images must both carry an immutable digest.
test -f "$ROOT/config/versions.env"
python3 - "$ROOT" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
versions = {}
for line in (root / "config/versions.env").read_text().splitlines():
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", line):
        key, value = line.split("=", 1)
        versions[key] = value.strip()

required = {
    "OPENAB_VERSION",
    "OPENAB_AGENT_RUNTIME",
    "OPENAB_IMAGE_OPENCODE",
    "OPENAB_IMAGE_CLAUDE",
    "OPENCODE_VERSION",
    "OMO_VERSION",
    "CODEGRAPH_VERSION",
    "CLAUDE_AGENT_ACP_VERSION",
    "CLAUDE_CODE_VERSION",
    "DOCLING_VERSION",
}
missing = required - versions.keys()
assert not missing, f"config/versions.env is missing {sorted(missing)}"

assert versions["OPENAB_AGENT_RUNTIME"] == "opencode", (
    "the committed default must be the OpenCode ACP runtime, got "
    f"{versions['OPENAB_AGENT_RUNTIME']!r}"
)

for key in ("OPENAB_IMAGE_OPENCODE", "OPENAB_IMAGE_CLAUDE"):
    image = versions[key]
    assert "@sha256:" in image, f"{key} must be pinned to a digest: {image}"
    tag = image.split("@", 1)[0].rsplit(":", 1)[1]
    assert tag not in ("latest", "beta", "stable"), f"{key} uses a floating tag: {tag}"
    assert versions["OPENAB_VERSION"] in tag, (
        f"{key} tag {tag} does not carry OPENAB_VERSION={versions['OPENAB_VERSION']}"
    )
assert versions["OPENAB_IMAGE_OPENCODE"].split("@")[0].endswith("-opencode")
assert versions["OPENAB_IMAGE_CLAUDE"].split("@")[0].endswith("-claude")

for key in ("OPENCODE_VERSION", "OMO_VERSION", "CODEGRAPH_VERSION", "CLAUDE_AGENT_ACP_VERSION", "CLAUDE_CODE_VERSION"):
    assert re.fullmatch(r"\d+\.\d+\.\d+", versions[key]), (
        f"{key} must be an exact version, got {versions[key]!r}"
    )

assert versions["OPENCODE_VERSION"] == "1.18.13", versions["OPENCODE_VERSION"]
assert versions["DOCLING_VERSION"] == "2.121.0", versions["DOCLING_VERSION"]

# The OMO version is pinned in versions.env and installed into the image. OpenCode
# must load that image-local package through a file URI; a registry package string
# makes OpenCode attempt a runtime npm download in a network-isolated container.
opencode_json = (root / "config/opencode/opencode.json").read_text()
assert '"file:///usr/local/lib/node_modules/oh-my-opencode-slim"' in opencode_json, (
    "config/opencode/opencode.json does not use the image-local OMO file URI"
)
assert "oh-my-opencode-slim@" not in opencode_json, (
    "config/opencode/opencode.json still asks OpenCode to download OMO from npm"
)
omo_json = (root / "config/opencode/oh-my-opencode-slim.json").read_text()
assert f'oh-my-opencode-slim@{versions["OMO_VERSION"]}/' in omo_json, (
    "the $schema in config/opencode/oh-my-opencode-slim.json is not pinned to "
    + versions["OMO_VERSION"]
)
PY

# No floating image reference anywhere in the build path.
if grep -q -E ':latest|:beta"|:stable"|@latest' "$ROOT/Dockerfile" "$ROOT/compose.yaml" "$ROOT/config/versions.env"; then
  printf 'A floating image or package reference is present in the build path.\n' >&2
  exit 1
fi
grep -Fq 'ARG OPENAB_IMAGE' "$ROOT/Dockerfile"
grep -Fq 'FROM ${OPENAB_IMAGE}' "$ROOT/Dockerfile"
grep -Fq 'ARG DOCLING_VERSION' "$ROOT/Dockerfile"
grep -Fq 'docling==${DOCLING_VERSION}' "$ROOT/Dockerfile"
! grep -Fq 'docling==2.121.0' "$ROOT/Dockerfile"
grep -Fq 'docling-tools models download layout tableformer --output-dir /opt/docling-models' "$ROOT/Dockerfile"
grep -Fq 'DOCLING_ARTIFACTS_PATH=/opt/docling-models' "$ROOT/Dockerfile"
grep -Fq 'DOCLING_VERSION: ${DOCLING_VERSION:?' "$ROOT/compose.yaml"
grep -Fq 'DOCLING_ARTIFACTS_PATH: /opt/docling-models' "$ROOT/compose.yaml"
grep -Fq 'USER node' "$ROOT/Dockerfile"
grep -Fq 'parse-document --help' "$ROOT/Dockerfile"
for forbidden in ocr vlm video asr libreoffice; do
  if grep -Eiq "(^|[^[:alnum:]_])${forbidden}([^[:alnum:]_]|$)" "$ROOT/Dockerfile"; then
    printf 'Dockerfile mentions forbidden Docling feature/package: %s\n' "$forbidden" >&2
    exit 1
  fi
done
python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
dockerfile = (root / "Dockerfile").read_text().lower()
parser = (root / "agents/bin/parse-document").read_text().lower()
for forbidden in ("rapidocr", "nemotron", "easyocr", "picture", "code-formula"):
    assert forbidden not in dockerfile, f"Dockerfile enables or prefetches {forbidden}"
    assert forbidden not in parser, f"parser enables or references {forbidden}"
assert "do_ocr=false" in parser
assert "do_table_structure=true" in parser
PY
grep -Fq 'npm i -g "@colbymchenry/codegraph@${CODEGRAPH_VERSION}"' "$ROOT/Dockerfile"
grep -Fq 'npm i -g "oh-my-opencode-slim@${OMO_VERSION}"' "$ROOT/Dockerfile"
grep -Fq 'npm i -g "@agentclientprotocol/claude-agent-acp@${CLAUDE_AGENT_ACP_VERSION}"' "$ROOT/Dockerfile"
python3 - "$ROOT" <<'PY'
import pathlib
import sys

dockerfile = (pathlib.Path(sys.argv[1]) / "Dockerfile").read_text()

# OpenCode is installed independently of whatever version the immutable OpenAB
# base happens to contain. Keep these checks about the contract, not an
# unrelated npm/apt command formatting detail.
for required in (
    'OPENCODE_PREFIX="/opt/opencode-${OPENCODE_VERSION}"',
    'npm install --prefix "/opt/opencode-${OPENCODE_VERSION}" "opencode-ai@${OPENCODE_VERSION}"',
    'test -x "$OPENCODE_PREFIX/node_modules/.bin/opencode"',
    'rm -f /usr/local/bin/opencode',
    'ln -s "$OPENCODE_PREFIX/node_modules/.bin/opencode" /usr/local/bin/opencode',
    'test "$(readlink /usr/local/bin/opencode)" = "$OPENCODE_PREFIX/node_modules/.bin/opencode"',
    'resolved="$(readlink -f "$(command -v opencode)")"',
    'test "$resolved" = "$(readlink -f "$OPENCODE_PREFIX/node_modules/.bin/opencode")"',
    '"$OPENCODE_PREFIX"/node_modules/opencode-ai/*)',
    'test "$(opencode --version)" = "$OPENCODE_VERSION"',
):
    assert required in dockerfile, f"Dockerfile omits OpenCode pin/path check: {required}"

assert 'npm install -g "opencode-ai@${OPENCODE_VERSION}"' not in dockerfile
assert 'opencode --version | grep -qF "$OPENCODE_VERSION"' not in dockerfile

# OMO is installed globally at build time, then checked from the exact path that
# config/opencode/opencode.json loads at runtime. This proves the package is
# image-local rather than merely proving that npm accepted the install command.
for required in (
    'npm i -g "oh-my-opencode-slim@${OMO_VERSION}"',
    'OMO_DIR=/usr/local/lib/node_modules/oh-my-opencode-slim',
    'test -f "$OMO_DIR/package.json"',
    "require(process.argv[1]).version",
    '"$OMO_DIR/package.json")" = "$OMO_VERSION"',
    "require(process.argv[1]).main",
    'test -n "$OMO_MAIN"',
    'test -f "$OMO_DIR/$OMO_MAIN"',
    'test -r "$OMO_DIR/$OMO_MAIN"',
):
    assert required in dockerfile, f"Dockerfile omits image-local OMO verification: {required}"
PY
grep -Fq 'command -v claude-agent-acp' "$ROOT/Dockerfile"
grep -Fq 'CLAUDE_AGENT_ACP_BIN=/usr/local/bin/claude-agent-acp' "$ROOT/Dockerfile"
grep -Fq 'test "$(command -v claude-agent-acp)" = "$CLAUDE_AGENT_ACP_BIN"' "$ROOT/Dockerfile"
grep -Fq 'CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude' "$ROOT/Dockerfile"
grep -Fq 'npm i -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"' "$ROOT/Dockerfile"
grep -Fq 'OPENAB_IMAGE: ${OPENAB_IMAGE:?' "$ROOT/compose.yaml"
grep -Fq 'CLAUDE_AGENT_ACP_VERSION: ${CLAUDE_AGENT_ACP_VERSION:?' "$ROOT/compose.yaml"
grep -Fq 'CLAUDE_AGENT_ACP_BIN: /usr/local/bin/claude-agent-acp' "$ROOT/compose.yaml"
grep -Fq 'CLAUDE_CODE_VERSION: ${CLAUDE_CODE_VERSION:?' "$ROOT/compose.yaml"
grep -Fq 'CLAUDE_CODE_EXECUTABLE: /usr/local/bin/claude' "$ROOT/compose.yaml"

# ------------------------------------------------- OpenCode ACP and rollback
# `opencode acp` is the default; Claude ACP is both an OMO specialist and a
# complete rollback path, not a deleted path.
python3 - "$ROOT" <<'PY'
import json, pathlib, sys, tomllib

root = pathlib.Path(sys.argv[1])
default = tomllib.loads((root / "config/openab.toml").read_text())
rollback = tomllib.loads((root / "config/openab.claude-acp.toml").read_text())
omo = json.loads((root / "config/opencode/oh-my-opencode-slim.json").read_text())

assert default["agent"]["command"] == "opencode", default["agent"]["command"]
assert default["agent"]["args"] == ["acp"], default["agent"]["args"]
for key in ("COMPANY_GATEWAY_API_KEY", "COMPANY_GATEWAY_BASE_URL", "SLACK_BOT_TOKEN"):
    assert key in default["agent"]["inherit_env"], f"{key} is not inherited by the agent"
for cfg in (default, rollback):
    assert "CLAUDE_CONFIG_DIR" in cfg["agent"]["inherit_env"]
    for key in ("PARSE_DOCUMENT_ALLOWED_HOST", "DOCLING_ARTIFACTS_PATH"):
        assert key in cfg["agent"]["inherit_env"], (
            f"{key} is not inherited by {cfg['agent']['command']} after OpenAB env_clear"
        )

claude_bin = "/usr/local/bin/claude-agent-acp"
assert rollback["agent"]["command"] == "claude-agent-acp", rollback["agent"]["command"]
assert omo["acpAgents"]["claude-code"]["command"] == claude_bin, omo["acpAgents"]
assert rollback["agent"]["args"] == []
assert rollback["agent"]["working_dir"] == "/home/node/code"

# Everything except [agent] is a permission or runtime setting. If the two files
# drift, a rollback silently changes who may talk to the bot.
for section in ("slack", "pool", "reactions"):
    assert default[section] == rollback[section], (
        f"[{section}] differs between config/openab.toml and "
        "config/openab.claude-acp.toml"
    )
assert default["stt"] == rollback["stt"], "[stt] differs between default and rollback"
assert default["filestore"] == rollback["filestore"], "[filestore] differs between runtimes"
assert default["filestore"]["max_file_size_mb"] == 50
PY

# lib.sh must map the runtime onto exactly these two images and configs.
grep -Fq 'OPENAB_IMAGE="$OPENAB_IMAGE_OPENCODE"' "$ROOT/scripts/lib.sh"
grep -Fq 'OPENAB_IMAGE="$OPENAB_IMAGE_CLAUDE"' "$ROOT/scripts/lib.sh"
grep -Fq 'OPENAB_CONFIG="./config/openab.toml"' "$ROOT/scripts/lib.sh"
grep -Fq 'OPENAB_CONFIG="./config/openab.claude-acp.toml"' "$ROOT/scripts/lib.sh"
grep -Fq '${OPENAB_CONFIG:?' "$ROOT/compose.yaml"

# Both runtimes must be selectable without editing anything but versions.env.
# load_versions resolves the image and config; run it for each value. The
# runtime is passed as an argument, never through the environment.
for runtime in opencode claude; do
  (
    set -euo pipefail
    # shellcheck source=scripts/lib.sh
    source "$ROOT/scripts/lib.sh"
    load_versions "$ROOT" "$runtime"
    test "$OPENAB_AGENT_RUNTIME" = "$runtime"
    test -n "$OPENAB_IMAGE"
    test -f "$ROOT/${OPENAB_CONFIG#./}"
  ) || {
    printf 'load_versions failed for runtime %s\n' "$runtime" >&2
    exit 1
  }
done
if bash -c 'source "$1/scripts/lib.sh"; load_versions "$1" bogus' _ "$ROOT" 2>/dev/null; then
  printf 'load_versions accepted an unknown runtime override.\n' >&2
  exit 1
fi

# --------------------------------------------- versions.env is the only source
# An ambient value that disagrees with config/versions.env must abort, not win.
# Otherwise a stray export builds a different image from the reviewed file and
# nothing says so. This is what `./scripts/compose.sh --runtime <x>` exists for.
while IFS='=' read -r key ambient; do
  if env "$key=$ambient" bash -c 'source "$1/scripts/lib.sh"; load_versions "$1"' _ "$ROOT" 2>/dev/null; then
    printf 'load_versions let the environment override %s.\n' "$key" >&2
    exit 1
  fi
  # An explicit override does not launder a disagreeing environment either. The
  # override here is opencode, so the ambient runtime (claude) still disagrees.
  if env "$key=$ambient" bash -c 'source "$1/scripts/lib.sh"; load_versions "$1" opencode' _ "$ROOT" 2>/dev/null; then
    printf 'load_versions let the environment override %s when a runtime was given.\n' "$key" >&2
    exit 1
  fi
done <<'AMBIENT'
OPENAB_AGENT_RUNTIME=claude
OPENAB_VERSION=9.9.9
OPENAB_IMAGE_OPENCODE=ghcr.io/openabdev/openab:9.9.9-opencode@sha256:0000000000000000000000000000000000000000000000000000000000000000
OPENAB_IMAGE_CLAUDE=ghcr.io/openabdev/openab:9.9.9-claude@sha256:0000000000000000000000000000000000000000000000000000000000000000
OPENCODE_VERSION=9.9.9
OMO_VERSION=9.9.9
CODEGRAPH_VERSION=9.9.9
CLAUDE_AGENT_ACP_VERSION=9.9.9
CLAUDE_CODE_VERSION=9.9.9
AMBIENT

# An ambient value that agrees with the file is not an override, and must keep
# working: deploy.sh loads versions and then calls scripts/compose.sh. The same
# has to hold when the runtime came from an explicit override.
(
  set -euo pipefail
  # shellcheck source=scripts/lib.sh
  source "$ROOT/scripts/lib.sh"
  load_versions "$ROOT"
  load_versions "$ROOT"
) || {
  printf 'load_versions rejected its own exported values; deploy.sh cannot nest.\n' >&2
  exit 1
}
(
  set -euo pipefail
  # shellcheck source=scripts/lib.sh
  source "$ROOT/scripts/lib.sh"
  load_versions "$ROOT" claude
  load_versions "$ROOT" claude
  test "$OPENAB_CONFIG" = ./config/openab.claude-acp.toml
) || {
  printf 'load_versions rejected a repeated runtime override.\n' >&2
  exit 1
}

# The rollback dry-run goes through the flag, so the flag has to be parsed.
grep -Fq -- '--runtime)' "$ROOT/scripts/compose.sh"
grep -Fq 'load_versions "$ROOT" "$RUNTIME_OVERRIDE"' "$ROOT/scripts/compose.sh"
if grep -rn -- 'OPENAB_AGENT_RUNTIME=claude \./scripts/compose\.sh' \
  "$ROOT/docs" "$ROOT/README.md" "$ROOT/CLAUDE.md"; then
  printf 'The docs still tell people to override the runtime through the environment.\n' >&2
  exit 1
fi

# deploy.sh must verify the runtime it just started, both ways.
grep -Fq 'opencode --version | grep -qF' "$ROOT/scripts/deploy.sh"
grep -Fq 'npm ls -g --depth=0 oh-my-opencode-slim' "$ROOT/scripts/deploy.sh"
grep -Fq 'command -v claude-agent-acp' "$ROOT/scripts/deploy.sh"
grep -Fq 'test "$CLAUDE_AGENT_ACP_BIN" = /usr/local/bin/claude-agent-acp' "$ROOT/scripts/deploy.sh"
grep -Fq 'test "$CLAUDE_CODE_EXECUTABLE" = /usr/local/bin/claude' "$ROOT/scripts/deploy.sh"
grep -Fq '"$CLAUDE_CODE_EXECUTABLE" --version | grep -qF "$CLAUDE_CODE_VERSION"' "$ROOT/scripts/deploy.sh"
grep -Fq 'test -w /home/node/.claude' "$ROOT/scripts/deploy.sh"
grep -Fq 'touch /home/node/.claude/.deploy-write-probe' "$ROOT/scripts/deploy.sh"
grep -Fq 'test -w /home/node/.local/share/opencode' "$ROOT/scripts/deploy.sh"

# deploy.sh must not read as "everything is verified". It has to name what it did
# not check, and the runbook has to carry the matching manual gate.
grep -Fq 'NOT VERIFIED HERE' "$ROOT/scripts/deploy.sh"
grep -Fq '人工 release gate' "$ROOT/scripts/deploy.sh"
grep -Fq '人工 release gate' "$ROOT/docs/runbook.md"
for item in 'slack-thread-artifact against real Slack' 'company-image against the real company gateway' 'Artifact cleanup' 'STT'; do
  grep -Fq "$item" "$ROOT/scripts/deploy.sh" || {
    printf 'scripts/deploy.sh does not list "%s" as unverified.\n' "$item" >&2
    exit 1
  }
done

# ------------------------------------------------------- OpenCode/OMO config
python3 - "$ROOT" <<'PY'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
oc = json.loads((root / "config/opencode/opencode.json").read_text())

assert oc["autoupdate"] is False, "OpenCode must not self-update off a pinned image"
assert oc["share"] == "disabled"
assert oc["snapshot"] is False, "the project tree is read-only, snapshots would fail"
assert oc["plugin"] == ["file:///usr/local/lib/node_modules/oh-my-opencode-slim"], oc["plugin"]
assert oc["permission"]["edit"] == "deny", "the bot is read-only"
bash = oc["permission"]["bash"]
for pattern in ("gh *", "git push*", "git commit*", "git checkout*", "codegraph init*"):
    assert bash.get(pattern) == "deny", f"bash permission for {pattern!r} is not deny"

# The existing mounts stay the source of truth: skills come from the work-helper
# snapshot, the agent contract from agents/CLAUDE.md.
assert oc["skills"]["paths"] == ["/home/node/.claude/skills"], oc["skills"]
assert oc["instructions"] == ["/home/node/CLAUDE.md"], oc["instructions"]

# The company gateway only serves the Responses API (the same one
# agents/bin/company-image posts to). OpenCode picks the SDK factory off this
# `npm` field, and @ai-sdk/openai-compatible has no `responses` factory, so it
# posts to {baseURL}/chat/completions and the gateway answers HTTP 405. That
# shipped once. tests/provider-route.py derives the route; this pins the name.
assert oc["provider"]["company"]["npm"] == "@ai-sdk/openai", (
    "the company provider must use @ai-sdk/openai (Responses API); see "
    "docs/adr/0010-company-provider-uses-the-responses-api.md"
)

# The gateway credentials are referenced, never inlined.
opts = oc["provider"]["company"]["options"]
assert opts["baseURL"] == "{env:COMPANY_GATEWAY_BASE_URL}", opts
assert opts["apiKey"] == "{env:COMPANY_GATEWAY_API_KEY}", opts

# Slack v1 accepts text, image and audio. Image input only reaches the model if
# the model metadata declares it.
models = oc["provider"]["company"]["models"]
for name, model in models.items():
    assert "image" in model["modalities"]["input"], f"{name} cannot take image input"
assert oc["model"] in (f"company/{m}" for m in models)
assert oc["small_model"] in (f"company/{m}" for m in models)

omo = json.loads((root / "config/opencode/oh-my-opencode-slim.json").read_text())
assert omo["autoUpdate"] is False, "OMO must not self-update off a pinned image"
preset = omo["presets"][omo["preset"]]
assert preset["orchestrator"]["model"] == "company/gpt-5.6-terra", "Terra synthesises"
assert preset["explorer"]["model"] == "company/gpt-5.6-luna", "Luna retrieves"
assert preset["librarian"]["model"] == "company/gpt-5.6-luna", "Luna retrieves"
assert omo["image_routing"] == "direct", "image attachments go to the orchestrator"
known = {f"company/{m}" for m in models}
for agent, cfg in preset.items():
    assert cfg["model"] in known, (
        f"OMO preset agent {agent} uses {cfg['model']}, which config/opencode/"
        "opencode.json does not declare"
    )
assert omo["companion"]["enabled"] is False, "no desktop window in a container"

# Claude Code is an OMO specialist inside this same container. It invokes the
# image-installed adapter directly; runtime npx download is not allowed. Routing
# is OMO Slim's built-in autonomous LLM routing, not a deployment-level trigger.
claude_agent = omo["acpAgents"]["claude-code"]
assert claude_agent["command"] == "/usr/local/bin/claude-agent-acp", claude_agent
assert claude_agent["args"] == [], claude_agent
assert "npx" not in json.dumps(claude_agent), claude_agent
assert "orchestratorPrompt" not in claude_agent, claude_agent
assert "!claude" not in json.dumps(claude_agent), claude_agent
assert "prefix" not in claude_agent["description"].lower(), claude_agent["description"]
assert "自行決定" in claude_agent["description"], claude_agent["description"]
active_routing_docs = (
    "CONTEXT.md",
    "agents/CLAUDE.md",
    "README.md",
    "docs/runbook.md",
    "config/slack-home.json",
    "docs/system-design.md",
)
for name in active_routing_docs:
    text = (root / name).read_text()
    assert "!claude" not in text, f"{name} retains the removed Slack trigger"
    assert "不需要特殊 prefix" in text, f"{name} omits the no-prefix routing policy"
    assert "依任務自行決定" in text, f"{name} omits autonomous task routing"
    assert "LLM routing" in text, f"{name} omits the LLM routing description"
    assert "非 deterministic" in text, f"{name} omits nondeterministic routing"
    assert "不保證每個複雜工作" in text, f"{name} promises too much Claude delegation"
    for forbidden in ("強制且可預期", "固定 prefix", "deterministic explicit trigger"):
        assert forbidden not in text, f"{name} retains the old mandatory trigger policy: {forbidden}"

for name in (
    "CONTEXT.md",
    "agents/CLAUDE.md",
    "README.md",
    "docs/runbook.md",
    "docs/system-design.md",
    "docs/adr/0007-single-container-opencode-runtime.md",
):
    text = (root / name).read_text()
    assert "@claude-code" in text and "ACP wrapper" in text, (
        f"{name} omits wrapper routing"
    )
    assert "orchestrator 不直接啟動 ACP" in text, f"{name} permits direct ACP startup"
    assert "委派失敗" in text, f"{name} omits explicit delegation failure handling"
    assert "fallback" in text.lower() and "靜默" in text, f"{name} omits no-silent-fallback policy"

adr = (root / "docs/adr/0007-single-container-opencode-runtime.md").read_text()
assert "## Implementation update" in adr
assert "delegate claude-code:" in adr, "ADR 0007's historical Decision was rewritten"
assert "目前使用 OMO Slim v2.2.15 內建的 autonomous routing" in adr
assert "上方 Decision 的 trigger 是本 ADR 的歷史紀錄" in adr
assert "../../config/opencode/oh-my-opencode-slim.json" in adr
# The work-helper catalog is not trimmed here: no agent narrows skills or MCPs,
# and no catalog-level disable list exists.
for agent, cfg in preset.items():
    assert cfg["skills"] == ["*"], f"{agent} trims the skill catalog"
    assert cfg["mcps"] == ["*"], f"{agent} trims the MCP catalog"
for key in ("disabled_skills", "disabled_mcps", "disabled_agents", "disabled_tools"):
    assert key not in omo, f"{key} trims the catalog; behaviour limits belong in agents/CLAUDE.md"

# Every model the gateway must expose, in one place, so the runbook can list it.
assert set(models) == {"gpt-5.6-terra", "gpt-5.6-luna"}, sorted(models)
PY

grep -Fq 'opencode-data:/home/node/.local/share/opencode' "$ROOT/compose.yaml"
grep -Fq 'opencode-cache:/home/node/.cache' "$ROOT/compose.yaml"
grep -Fq 'opencode-state:/home/node/.opencode' "$ROOT/compose.yaml"
grep -Fq 'OPENCODE_CONFIG_DIR: /home/node/.config/opencode' "$ROOT/compose.yaml"
grep -Fq 'XDG_STATE_HOME: /home/node/.opencode' "$ROOT/compose.yaml"
grep -Fq 'claude-credentials:/home/node/.claude' "$ROOT/compose.yaml"
grep -Fq 'CLAUDE_CONFIG_DIR: /home/node/.claude' "$ROOT/compose.yaml"

# --------------------------------- OpenCode's writable directories must be writable
# OpenCode needs two writable directories and killed `opencode acp` at startup
# once for each of them:
#   /home/node/.config/opencode  (OPENCODE_CONFIG_DIR, mounted read-only)
#     Unexpected error: FileSystem.writeFile (/home/node/.config/opencode/.gitignore)
#   /home/node/.opencode         (OpenCode's own state root, not mounted at all)
#     Unexpected error; Unknown: FileSystem.writeFile (/home/node/.opencode/.gitignore)
# Both are now dedicated writable named volumes, and in the config dir each
# committed config file is a separate read-only bind on top, so the agent still
# cannot rewrite provider or permission settings. /home/node itself stays
# read-only: widening it would undo every read-only mount below it.
# This parses compose.yaml as text on purpose — it has to catch the mount shape
# on a machine with no Docker, which is where both bugs shipped from.
python3 - "$ROOT" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
compose = (root / "compose.yaml").read_text()

match = re.search(r"^\s*OPENCODE_CONFIG_DIR:\s*(\S+)\s*$", compose, re.M)
assert match, "compose.yaml no longer sets OPENCODE_CONFIG_DIR"
config_dir = match.group(1)


def split_mount(spec):
    """Split src:dst[:opts]. Colons inside ${...} are not separators."""
    parts, current, depth, i = [], "", 0, 0
    while i < len(spec):
        if spec.startswith("${", i):
            depth, current, i = depth + 1, current + "${", i + 2
            continue
        char = spec[i]
        if char == "}" and depth:
            depth -= 1
        elif char == ":" and depth == 0:
            parts.append(current)
            current, i = "", i + 1
            continue
        current, i = current + char, i + 1
    parts.append(current)
    return parts


# Every mount is one line in this file, so a line scan is enough and needs no yaml.
mounts = {}
for line in compose.splitlines():
    stripped = line.strip()
    if not stripped.startswith("- ") or stripped.startswith("- #"):
        continue
    spec = stripped[2:].strip()
    if ":" not in spec or spec.startswith(("path:", "required:")):
        continue
    parts = split_mount(spec)
    if len(parts) < 2 or not parts[1].startswith("/"):
        continue
    source, target = parts[0], parts[1]
    options = set(parts[2].split(",")) if len(parts) > 2 else set()
    assert target not in mounts, f"compose.yaml mounts {target} twice"
    mounts[target] = (source, options)

declared = set(re.findall(r"^  ([a-z0-9-]+):\s*$", compose.split("\nvolumes:\n")[-1], re.M))

# 1. The config dir itself: a declared named volume, writable, never a bind of the
#    whole config/opencode directory.
assert config_dir in mounts, f"nothing is mounted at OPENCODE_CONFIG_DIR ({config_dir})"
source, options = mounts[config_dir]
assert "ro" not in options, (
    f"{config_dir} is mounted read-only; `opencode acp` cannot write its .gitignore "
    "and dies at startup"
)
assert not source.startswith(("/", "./", "${")), (
    f"{config_dir} must be a named volume so it is writable under a read-only "
    f"rootfs, got the bind source {source!r}"
)
assert source in declared, f"named volume {source!r} is not declared in compose.yaml"

# 2. Each committed config file is mounted read-only, by itself, at the right path.
config_files = sorted(p.name for p in (root / "config/opencode").iterdir() if p.is_file())
assert config_files, "config/opencode has no config files"
for name in config_files:
    target = f"{config_dir}/{name}"
    assert target in mounts, (
        f"config/opencode/{name} is not mounted at {target}; OpenCode would read the "
        "empty named volume instead of the committed config"
    )
    source, options = mounts[target]
    assert source == f"./config/opencode/{name}", source
    assert "ro" in options, (
        f"{target} is writable; the agent could rewrite provider or permission settings"
    )

# 3. Nothing else is mounted into the config dir, so a renamed or deleted config
#    file cannot leave a stale mount behind pointing at a missing source.
expected = {config_dir} | {f"{config_dir}/{name}" for name in config_files}
stale = {t for t in mounts if t == config_dir or t.startswith(config_dir + "/")} - expected
assert not stale, f"compose.yaml mounts paths that config/opencode does not have: {sorted(stale)}"

# 4. An empty named volume inherits the ownership of the mount point in the image.
#    If the Dockerfile does not create the directory it lands as root:root and the
#    writable volume is writable by nobody.
dockerfile = (root / "Dockerfile").read_text()
assert re.search(rf"mkdir -p [^\n]*{re.escape(config_dir)}", dockerfile), (
    f"the Dockerfile must create {config_dir} so the named volume inherits node's "
    "ownership instead of root's"
)
assert re.search(r'chown -R "\$HOST_UID:\$HOST_GID" /home/node\b', dockerfile), (
    "the Dockerfile no longer chowns /home/node to the host uid"
)

# 4a. Claude Code's credential/state volume has the same fresh-volume ownership
#     requirement. Keep the existing rollback settings mount as a child file.
claude_dir = "/home/node/.claude"
assert claude_dir in mounts, f"nothing is mounted at {claude_dir}"
source, options = mounts[claude_dir]
assert source == "claude-credentials", source
assert "ro" not in options, f"{claude_dir} is mounted read-only"
assert source in declared, f"named volume {source!r} is not declared in compose.yaml"
settings = f"{claude_dir}/settings.json"
assert settings in mounts
assert mounts[settings][0] == "./managed-claude-settings.json"
assert "ro" in mounts[settings][1]
assert re.search(rf"mkdir -p [^\n]*{re.escape(claude_dir)}", dockerfile), (
    f"the Dockerfile must create {claude_dir} so a fresh Claude volume inherits node ownership"
)

# 5. deploy.sh has to prove all of this against a running container, both ways.
deploy = (root / "scripts/deploy.sh").read_text()
# The trailing guard matters: `test -w <dir>/opencode.json` must not satisfy the
# check for the directory itself.
assert re.search(rf"test -w {re.escape(config_dir)}(?![/\w])", deploy), (
    "scripts/deploy.sh does not check that the OpenCode config dir is writable"
)
assert re.search(rf"touch {re.escape(config_dir)}/\.[\w-]+", deploy), (
    "scripts/deploy.sh does not actually write a dotfile into the config dir, which "
    "is the operation that failed in production"
)
for name in config_files:
    assert f"test ! -w {config_dir}/{name}" in deploy, (
        f"scripts/deploy.sh does not check that {config_dir}/{name} stays read-only"
    )

# 6. OpenCode's own state root. This is the second startup crash: fixing the
#    config dir left ~/.opencode unmounted under a read-only rootfs, so
#    `opencode acp` still died on FileSystem.writeFile and the ACP link closed.
#    It is NOT /home/node/.openab — that is OpenAB's state bind, a different path
#    one character apart, and the two must not be confused for each other.
state_dir = "/home/node/.opencode"
assert state_dir in mounts, (
    f"nothing is mounted at {state_dir}; OpenCode writes its .gitignore and state "
    "there and `opencode acp` dies at startup under the read-only rootfs"
)
source, options = mounts[state_dir]
assert "ro" not in options, f"{state_dir} is mounted read-only; `opencode acp` cannot start"
assert not source.startswith(("/", "./", "${")), (
    f"{state_dir} must be a named volume so it is writable under a read-only "
    f"rootfs, got the bind source {source!r}"
)
assert source in declared, f"named volume {source!r} is not declared in compose.yaml"
assert "/home/node/.openab" in mounts, "the OpenAB state mount disappeared"
assert mounts["/home/node/.openab"][0] != source, (
    "/home/node/.openab and /home/node/.opencode share a source; they are different "
    "directories for different programs"
)

# 7. Widening /home/node instead of mounting the one directory would silently make
#    every read-only mount below it writable, so the fix must stay narrow.
assert "/home/node" not in mounts, (
    "compose.yaml mounts /home/node itself; a writable home undoes the read-only "
    "config, skills and snapshot mounts underneath it"
)

# 8. Same ownership trap as the config dir: an empty named volume inherits the
#    mount point's ownership from the image, so the directory has to exist there.
assert re.search(rf"mkdir -p [^\n]*(?<![\w.-]){re.escape(state_dir)}(?![\w.-])", dockerfile), (
    f"the Dockerfile must create {state_dir} so the named volume inherits node's "
    "ownership instead of root's"
)

# 9. And deploy.sh has to prove it against a running container, with the same
#    dotfile write that failed, not just a permission-bit check.
assert re.search(rf"test -w {re.escape(state_dir)}(?![/\w])", deploy), (
    f"scripts/deploy.sh does not check that {state_dir} is writable"
)
assert re.search(rf"touch {re.escape(state_dir)}/\.[\w-]+", deploy), (
    f"scripts/deploy.sh does not actually write a dotfile into {state_dir}, which is "
    "the operation that failed in production"
)
assert re.search(r"test ! -w /home/node(?![/\w.-])", deploy), (
    "scripts/deploy.sh does not check that /home/node itself stayed read-only"
)
assert re.search(rf"test -w {re.escape(claude_dir)}(?![/\w])", deploy), (
    f"scripts/deploy.sh does not check that {claude_dir} is writable"
)
assert re.search(rf"touch {re.escape(claude_dir)}/\.[\w-]+", deploy), (
    f"scripts/deploy.sh does not write a probe into {claude_dir}"
)
PY

grep -Fq 'CLAUDE_CODE_EXECUTABLE: /usr/local/bin/claude' "$ROOT/compose.yaml"
if grep -R -n -F 'permissionMode": "ask"' \
  "$ROOT/config" "$ROOT/agents" "$ROOT/docs" "$ROOT/README.md" "$ROOT/CLAUDE.md" ||
   grep -R -n -F '只有在通過 delegation gate' \
  "$ROOT/config" "$ROOT/agents" "$ROOT/docs" "$ROOT/README.md" "$ROOT/CLAUDE.md"; then
  printf 'Claude ACP policy still relies on an interactive or prompt-enforced gate.\n' >&2
  exit 1
fi

# The gateway credentials must be documented as env, never committed.
grep -q '^COMPANY_GATEWAY_BASE_URL=' "$ROOT/env/openab.env.example"
grep -q '^COMPANY_GATEWAY_API_KEY=replace-me$' "$ROOT/env/openab.env.example"

# ------------------------------------------------------------- company-image
# The one sanctioned image path. It must stay narrow, must be reachable from
# both runtimes, and must never carry an endpoint or a key in its source.
python3 - "$ROOT" <<'PY'
import ast, json, pathlib, re, sys, tomllib

root = pathlib.Path(sys.argv[1])
src = (root / "agents/bin/company-image").read_text()
tree = ast.parse(src)


def value_of(node):
    """literal_eval, but Path("x") reads as "x" so the roots compare as strings."""
    if isinstance(node, ast.Call) and getattr(node.func, "id", None) == "Path":
        return value_of(node.args[0])
    if isinstance(node, ast.Tuple):
        return tuple(value_of(item) for item in node.elts)
    return ast.literal_eval(node)


consts = {}
for node in tree.body:
    if not isinstance(node, ast.Assign):
        continue
    for target in node.targets:
        if not isinstance(target, ast.Name):
            continue
        try:
            consts[target.id] = value_of(node.value)
        except (ValueError, TypeError, AttributeError):
            pass

# Output is PNG, into drafts, nowhere else.
assert consts["DRAFTS_ROOT"] == "/home/node/drafts", consts.get("DRAFTS_ROOT")
assert consts["SOURCE_ROOTS"] == (
    "/home/node/drafts",
    "/home/node/.openab",
    "/tmp",
), consts.get("SOURCE_ROOTS")
assert "/home/node/code" not in consts["SOURCE_ROOTS"], "read-only snapshots are not an image source"

# Fixed generate/edit, a closed size list, no free-form anything.
assert set(consts["ALLOWED_SIZES"]) == {"1024x1024", "1024x1536", "1536x1024"}, consts["ALLOWED_SIZES"]
assert consts["DEFAULT_SIZE"] in consts["ALLOWED_SIZES"]
subcommands = set(re.findall(r'modes\.add_parser\(\s*"([a-z]+)"', src))
assert subcommands == {"generate", "edit"}, sorted(subcommands)
flags = set(re.findall(r'add_argument\(\s*"(--[a-z-]+)"', src))
assert flags == {"--prompt", "--size", "--name", "--source"}, sorted(flags)

# The endpoint and the key come from the runtime env and only from there.
assert 'os.environ.get("COMPANY_GATEWAY_BASE_URL"' in src
assert 'os.environ.get("COMPANY_GATEWAY_API_KEY"' in src
for pattern in (r"https?://(?!gateway\.example)", r"Bearer [A-Za-z0-9]", r"sk-[A-Za-z0-9]"):
    assert not re.search(pattern, src), f"company-image hard-codes {pattern}"

# The model has to be one config/opencode/opencode.json actually declares.
oc = json.loads((root / "config/opencode/opencode.json").read_text())
assert consts["MODEL"] in oc["provider"]["company"]["models"], consts["MODEL"]

# Both runtimes must be able to run it: same image, and both OpenAB configs
# have to hand the gateway env to the agent process.
dockerfile = (root / "Dockerfile").read_text()
assert "COPY agents/bin/company-image /usr/local/bin/company-image" in dockerfile
assert "COPY agents/bin/slack-thread-artifact /usr/local/bin/slack-thread-artifact" in dockerfile
assert "company-image --help" in dockerfile, "the build never proves the CLI runs"
for name in ("config/openab.toml", "config/openab.claude-acp.toml"):
    cfg = tomllib.loads((root / name).read_text())
    for key in ("COMPANY_GATEWAY_API_KEY", "COMPANY_GATEWAY_BASE_URL"):
        assert key in cfg["agent"]["inherit_env"], (
            f"{name} does not inherit {key}; company-image cannot run under that runtime"
        )

# Neither runtime's permission list may block it.
assert oc["permission"]["bash"].get("company-image *") == "allow"
assert oc["permission"]["bash"].get("slack-thread-artifact *") == "allow"
claude = json.loads((root / "managed-claude-settings.json").read_text())
assert "Bash(company-image *)" in claude["permissions"]["allow"]
assert "Bash(slack-thread-artifact *)" in claude["permissions"]["allow"]
for rule in claude["permissions"]["deny"]:
    assert "company-image" not in rule, rule
PY

# ----------------------------------------------- slack-thread-artifact
python3 - "$ROOT" <<'PY'
import ast, pathlib, sys

root = pathlib.Path(sys.argv[1])
src = (root / "agents/bin/slack-thread-artifact").read_text()
tree = ast.parse(src)
flags = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and getattr(node.func, "attr", None) == "add_argument" and node.args:
        value = getattr(node.args[0], "value", None)
        if isinstance(value, str):
            flags.add(value)
assert flags == {"--file", "--channel", "--thread-ts"}, flags
assert 'DRAFTS_ROOT = Path("/home/node/drafts")' in src
assert 'files.getUploadURLExternal' in src
assert 'files.completeUploadExternal' in src
assert 'SLACK_BOT_TOKEN' in src
assert '".png": "image/png"' in src and '".md": "text/markdown"' in src and '".html": "text/html"' in src

# 兩個 Slack Web API method 的 body 必須是 form。JSON body 送給
# files.getUploadURLExternal 會被 Slack 回 invalid_arguments，bot 就完全傳不了檔。
# tests/slack-thread-artifact.py 驗實際 header 與 body；這裡擋的是「改回 JSON」。
assert "urlencode(fields).encode(" in src, (
    "slack-thread-artifact does not urlencode its Slack API body"
)
assert '"Content-Type": "application/x-www-form-urlencoded"' in src, (
    "slack-thread-artifact is not sending a form content type to the Slack Web API"
)
assert '"Content-Type": "application/json"' not in src, (
    "slack-thread-artifact sends a JSON body again; files.getUploadURLExternal "
    "answers invalid_arguments to that"
)
# complete 的 files 是 form 裡的一個 JSON 字串欄位，不是 nested JSON body。
assert '"files": json.dumps(' in src, (
    "the files field of files.completeUploadExternal is not a JSON string"
)
# 真正上傳 bytes 的那一段不是 Slack Web API，不能被順手改成 form。
assert 'headers={"Content-Type": mime}' in src, (
    "the binary upload no longer posts the raw bytes under the artifact mime"
)

# The path walk is the security property, so assert its shape, not just that a
# delete exists. resolve() must not come back: it follows symlinks, which is the
# hole the dirfd walk closes. tests/artifact-path-safety.py proves the behaviour.
assert ".resolve()" not in src, "slack-thread-artifact is resolving paths again"
assert "os.unlink(self.name, dir_fd=self.parent_fd)" in src, (
    "the draft is not deleted through the parent dirfd it was read from"
)
assert "identity(current) != identity(self.info)" in src, (
    "the draft is deleted without re-checking that it is still the same file"
)
for name in ("slack-thread-artifact", "company-image"):
    cli = (root / "agents/bin" / name).read_text()
    assert "O_DIRECTORY | O_NOFOLLOW" in cli, f"{name} walks directories without O_NOFOLLOW"
    assert "os.O_RDONLY | O_NOFOLLOW" in cli, f"{name} opens files without O_NOFOLLOW"
    assert ".resolve()" not in cli, f"{name} is resolving paths again"

# The image output has to be atomic and must never be written through a symlink.
image = (root / "agents/bin/company-image").read_text()
assert "os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW" in image, (
    "company-image creates output files without O_EXCL|O_NOFOLLOW"
)
assert "os.rename(temp, final, src_dir_fd=day_fd, dst_dir_fd=day_fd)" in image, (
    "company-image does not rename its temp file into place through the day dirfd"
)
assert "os.fsync(day_fd)" in image, "company-image does not fsync the output directory"
assert ".write_bytes(" not in image, "company-image writes output through a mutable path"
PY
grep -Fq 'slack-thread-artifact' "$ROOT/agents/CLAUDE.md"
grep -Fq '<sender_context>' "$ROOT/agents/CLAUDE.md"
grep -Fq '不是 ACP side-channel' "$ROOT/agents/CLAUDE.md"

# 「回原 thread」必須在三個地方都寫成信任約定，不是安全保證。少掉任何一個，讀到的人
# 就會把 prompt content 當成驗證過的授權資料。
grep -Fq '信任約定' "$ROOT/agents/CLAUDE.md"
grep -Fq '信任約定，不是安全保證' "$ROOT/docs/system-design.md"
grep -Fq '信任約定，不是安全保證' "$ROOT/docs/adr/0009-thread-artifact-upload-and-optional-stt.md"
grep -Fq 'prompt content' "$ROOT/docs/adr/0009-thread-artifact-upload-and-optional-stt.md"
grep -Fq 'sender context' "$ROOT/CONTEXT.md"
# 任何提到 sender_context 的檔案都必須在同一份檔案裡說它不是安全保證。分散在多份
# 文件時，只在其中一份寫免責等於其他幾份在單獨閱讀時讀起來像身分驗證。
python3 - "$ROOT" <<'PY'
import pathlib, subprocess, sys

root = pathlib.Path(sys.argv[1])
tracked = subprocess.run(
    ["git", "-C", str(root), "grep", "--untracked", "-l", "-F", "sender_context", "--",
     ".", ":(exclude)tests/static.sh", ":(exclude)runtime/"],
    capture_output=True, text=True, check=False,
).stdout.split()

# The CLI source and the agent contract say it in their own words; the docs use
# the shared phrase. Either counts, an absence does not.
disclaimers = (
    "信任約定",
    "不是安全保證",
    "並非不可竄改",
    "不是不可竄改",
    "不宣稱",
)
missing = []
for name in tracked:
    text = (root / name).read_text()
    if not any(phrase in text for phrase in disclaimers):
        missing.append(name)
assert not missing, (
    "these files mention sender_context without saying it is not a security "
    f"boundary: {missing}"
)
assert len(tracked) >= 4, f"expected sender_context to be documented in several files, got {tracked}"
PY
grep -Fq 'STT_BASE_URL' "$ROOT/env/openab.env.example"
grep -Fq '[stt]' "$ROOT/config/openab.toml"
grep -Fq 'STT_BASE_URL and STT_API_KEY must be set together' "$ROOT/scripts/preflight.sh"
grep -Fq 'slack-thread-artifact --help' "$ROOT/scripts/deploy.sh"

# --------------------------------------------------- artifact cleanup schedule
# 上傳失敗的 artifact 會留在 drafts，所以「最多保留 24 小時」必須真的有排程在跑。
# 這一段不是 grep 文件：它 render install script 會寫進 crontab 的那份文字，再用
# 假的 docker 實際跑一次 cleanup-artifacts.sh，確認它在 container 內執行的就是
# work-helper 的 `slack-list cleanup`，且失敗會被記下來並回非零。
test -x "$ROOT/scripts/cleanup-artifacts.sh"
grep -Fq 'render_crontab "$ROOT" "$SNAPSHOT_ROOT"' "$ROOT/scripts/install-sync-cron.sh"
grep -Fq 'CRON_MARKER_CLEANUP' "$ROOT/scripts/install-sync-cron.sh"

cron_render=$(bash -c 'source "$1/scripts/lib.sh"; render_crontab "$1" /srv/snapshots' _ "$ROOT")
CRON_RENDER="$cron_render" python3 - "$ROOT" <<'PY'
import os, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
lines = [line for line in os.environ["CRON_RENDER"].splitlines() if line.strip()]
assert len(lines) == 2, f"render_crontab printed {len(lines)} lines: {lines}"

jobs = {}
for line in lines:
    command, _, marker = line.partition("#")
    marker = marker.strip()
    assert marker, f"crontab line carries no marker comment: {line!r}"
    fields = command.split()
    schedule, rest = fields[:5], fields[5:]
    for field in schedule:
        assert re.fullmatch(r"[-0-9*/,]+", field), f"bad cron field {field!r} in {line!r}"
    assert rest, f"crontab line schedules nothing: {line!r}"
    jobs[marker] = (schedule, " ".join(rest))

assert set(jobs) == {"work-agent-snapshots", "work-agent-artifact-cleanup"}, sorted(jobs)

schedule, command = jobs["work-agent-artifact-cleanup"]
assert "scripts/cleanup-artifacts.sh" in command, command
assert (root / "scripts/cleanup-artifacts.sh").is_file(), "the scheduled script does not exist"
# Retention is 24h, so the job has to come round at least once an hour, every day.
assert schedule[1] == "*", f"artifact cleanup must run hourly, got {' '.join(schedule)}"
for field in schedule[2:]:
    assert field == "*", f"artifact cleanup must run every day, got {' '.join(schedule)}"

# 清理規則的正本是 container 內的 work-helper，不是這個 repo 的第二份實作。
cleanup = (root / "scripts/cleanup-artifacts.sh").read_text()
assert "/home/node/code/work-helper/bin/slack-list" in cleanup, (
    "cleanup-artifacts.sh does not call the container's slack-list"
)
assert 'exec -T backlog-agent "$CLEANUP_COMMAND" cleanup' in cleanup, (
    "cleanup-artifacts.sh does not run `slack-list cleanup` inside the container"
)
assert "FAILED" in cleanup, "cleanup-artifacts.sh does not record a failed run"
PY

# Now run it for real against a fake docker. No Docker, no container, no Slack.
cleanup_probe=$(mktemp -d)
trap 'rm -rf "$cleanup_probe"' EXIT
cat >"$cleanup_probe/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DOCKER_CALLS"
exit "${FAKE_DOCKER_EXIT:-0}"
FAKE
chmod +x "$cleanup_probe/docker"
cleanup_log=$cleanup_probe/state/work-agent/artifact-cleanup.log

# cleanup-artifacts.sh redirects to its log when stdout is not a tty, which is
# exactly how cron runs it, so assert on the log rather than on this shell.
if ! FAKE_DOCKER_CALLS="$cleanup_probe/calls" \
  XDG_STATE_HOME="$cleanup_probe/state" \
  PATH="$cleanup_probe:$PATH" \
  SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/nonexistent}" \
  "$ROOT/scripts/cleanup-artifacts.sh" >/dev/null 2>&1; then
  printf 'scripts/cleanup-artifacts.sh failed against a fake docker that exits 0.\n' >&2
  exit 1
fi
if ! grep -Fq 'exec -T backlog-agent /home/node/code/work-helper/bin/slack-list cleanup' \
  "$cleanup_probe/calls"; then
  printf 'cleanup-artifacts.sh did not run `slack-list cleanup` in the container. It ran:\n' >&2
  cat "$cleanup_probe/calls" >&2
  exit 1
fi
grep -Fq -- '-f' "$cleanup_probe/calls" # it went through scripts/compose.sh, not bare docker

# A failing cleanup must be logged and must exit non-zero, or a host that stops
# cleaning drafts looks exactly like a host that has nothing to clean.
: >"$cleanup_probe/calls"
if FAKE_DOCKER_CALLS="$cleanup_probe/calls" FAKE_DOCKER_EXIT=1 \
  XDG_STATE_HOME="$cleanup_probe/state" \
  PATH="$cleanup_probe:$PATH" \
  SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/nonexistent}" \
  "$ROOT/scripts/cleanup-artifacts.sh" >/dev/null 2>&1; then
  printf 'cleanup-artifacts.sh exited 0 even though the container command failed.\n' >&2
  exit 1
fi
if ! grep -Fq 'FAILED' "$cleanup_log"; then
  printf 'cleanup-artifacts.sh did not record the failure in %s\n' "$cleanup_log" >&2
  exit 1
fi
rm -rf "$cleanup_probe"
trap - EXIT

# The decision is a single container without a broker. Only the ADRs may name
# the dropped design, and only to record that it was dropped. Everywhere else a
# mention would be a live claim.
# `--untracked` matters here and in the two scans below: a new file that has not
# been committed yet is exactly where a stray claim or credential shows up, and
# plain `git grep` would not look at it. Ignored paths (.env, env/openab.env,
# runtime/) stay out, which is what we want.
if git -C "$ROOT" grep --untracked -n -E 'image-artifact broker|broker MCP|Slack token 不暴露|受限的 local (MCP|upload helper)' \
  -- . ':(exclude)tests/static.sh' ':(exclude)docs/adr/'; then
  printf 'A superseded broker/token-isolation claim is still outside the ADRs.\n' >&2
  exit 1
fi

# The declared Slack input and artifact output limits, stated once in the design.
grep -Fq 'text、image、audio' "$ROOT/docs/system-design.md"
grep -Fq 'text、image、audio' "$ROOT/agents/CLAUDE.md"
grep -Fq 'self-contained HTML' "$ROOT/docs/system-design.md"
grep -Fq 'self-contained HTML' "$ROOT/agents/CLAUDE.md"

# One mount for the whole snapshot root, one for the skills directory. Adding a
# repo must not require touching compose.yaml.
grep -Fq '${SNAPSHOT_ROOT:?set SNAPSHOT_ROOT in .env}:/home/node/code:ro,z' "$ROOT/compose.yaml"
grep -Fq '${SNAPSHOT_ROOT:?set SNAPSHOT_ROOT in .env}/work-helper/.claude/skills:/home/node/.claude/skills:ro,z' "$ROOT/compose.yaml"
if grep -q -E '/home/node/code/[A-Za-z0-9._-]+:ro' "$ROOT/compose.yaml"; then
  printf 'compose.yaml must not mount repos one by one.\n' >&2
  exit 1
fi
if grep -q -E '/home/node/\.claude/skills/[A-Za-z0-9._-]+' "$ROOT/compose.yaml"; then
  printf 'compose.yaml must not mount skills one by one.\n' >&2
  exit 1
fi
# CodeGraph: writable index outside the read-only tree, agent may only query.
grep -Fq '${SNAPSHOT_ROOT:?set SNAPSHOT_ROOT in .env}/.index:/home/node/code/.index:z' "$ROOT/compose.yaml"
grep -q 'CODEGRAPH_TELEMETRY: "0"' "$ROOT/compose.yaml"
grep -Fq 'ln -sfn "../.index/$name" "$target/.codegraph"' "$ROOT/scripts/update-snapshots.sh"
grep -Fq "grep -qxF '.codegraph'" "$ROOT/scripts/update-snapshots.sh"
grep -Fq 'codegraph explore' "$ROOT/agents/CLAUDE.md"
for sub in init index sync uninit daemon; do
  grep -Fq "Bash(codegraph $sub*)" "$ROOT/managed-claude-settings.json"
done

awk -F'|' '/^[^#]/ && NF { if ($1 !~ /^[A-Za-z0-9._-]+$/ || $2 !~ /^git@github\.com:/ || $3 !~ /^[A-Za-z0-9._\/-]+$/) exit 1 }' "$ROOT/config/repos.conf"

grep -q ':ro' "$ROOT/compose.yaml"
grep -Fq './agents/CLAUDE.md:/home/node/CLAUDE.md:ro,z' "$ROOT/compose.yaml"
if grep -Fq -- '- ./CLAUDE.md:/home/node/CLAUDE.md' "$ROOT/compose.yaml"; then
  printf 'Root CLAUDE.md must not be mounted into the container.\n' >&2
  exit 1
fi
if git -C "$ROOT" grep --untracked -n -E 'xoxb-[A-Za-z0-9-]{10,}|xapp-[A-Za-z0-9-]{10,}|github_pat_|sk-[A-Za-z0-9]{20,}' \
  -- . ':(exclude)tests/static.sh' ':(exclude)env/openab.env.example'; then
  printf 'A credential-like value is present in the repo.\n' >&2
  exit 1
fi

# Compose still has to render, both for the default runtime and for the Claude
# ACP rollback, and it must render only through scripts/compose.sh.
# `command -v docker` is not enough: WSL ships a shim that exists but fails.
if docker compose version >/dev/null 2>&1; then
  for runtime in opencode claude; do
    SNAPSHOT_ROOT=${SNAPSHOT_ROOT:-/nonexistent} \
      "$ROOT/scripts/compose.sh" --runtime "$runtime" config --quiet
  done
  if SNAPSHOT_ROOT=${SNAPSHOT_ROOT:-/nonexistent} docker compose -f "$ROOT/compose.yaml" config --quiet 2>/dev/null; then
    printf 'compose.yaml rendered without scripts/compose.sh; the version pins are bypassable.\n' >&2
    exit 1
  fi
else
  printf 'docker is not available; compose.yaml is only parsed locally.\n' >&2
  limited 'docker compose config (both runtimes) — compose.yaml was parsed locally instead'
  limited 'that plain `docker compose` still refuses to render without scripts/compose.sh'
  # Not a substitute for `compose config`, but it still catches an unresolved
  # variable or a mount source that stopped existing.
  for runtime in opencode claude; do
    status=0
    (
      set -euo pipefail
      # shellcheck source=scripts/lib.sh
      source "$ROOT/scripts/lib.sh"
      load_env "$ROOT"
      load_versions "$ROOT" "$runtime"
      python3 - "$ROOT" <<'PY'
import os, pathlib, re, sys

try:
    import yaml
except ImportError:
    # Exit 3 so the caller can record this as unverified instead of silently
    # counting a skipped parse as a passed check.
    print("pyyaml missing, compose.yaml not parsed.", file=sys.stderr)
    sys.exit(3)

root = pathlib.Path(sys.argv[1])
src = (root / "compose.yaml").read_text()
missing = []


def sub(match):
    name = match.group("name")
    if name in os.environ:
        return os.environ[name]
    if match.group("op") == ":-":
        return match.group("val") or ""
    missing.append(name)
    return ""


pattern = re.compile(
    r"\$\{(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?P<op>:\?|:-)?(?P<val>[^}]*)\}"
)
service = yaml.safe_load(pattern.sub(sub, src))["services"]["backlog-agent"]
assert not missing, f"unresolved compose variables: {sorted(set(missing))}"

declared = set(yaml.safe_load(src)["volumes"])
for volume in service["volumes"]:
    source = volume.split(":", 1)[0]
    if source.startswith("./"):
        assert (root / source[2:]).exists(), f"mount source is missing: {source}"
    elif not source.startswith("/"):
        assert source in declared, f"named volume {source} is not declared"
PY
    ) || status=$?
    case $status in
      0) ;;
      3) limited "local parse of compose.yaml for runtime $runtime — pyyaml is not installed" ;;
      *)
        printf 'compose.yaml does not render for runtime %s\n' "$runtime" >&2
        exit 1
        ;;
    esac
  done
fi

# Runbooks may name the manual deployment host when an operator must perform an
# external step; implementation files must not hard-code a host or user name.
if git -C "$ROOT" grep --untracked -n -E 'nettop|Nettop|(^|[^[:alnum:]_])henry([^[:alnum:]_]|$)|(^|[^[:alnum:]_])Henry([^[:alnum:]_]|$)' \
  -- . ':(exclude)tests/static.sh' ':(exclude)config/repos.conf' ':(exclude)README.md' ':(exclude)docs/'; then
  printf 'A deployment host or user name is hard-coded in the repo.\n' >&2
  exit 1
fi

# The CLIs' own contracts (request shape, PNG output, rejected input) and their
# path handling under attack are covered by mocked tests. No socket, no Docker,
# no gateway key, no Slack token.
"$ROOT/tests/parse-document.py"
"$ROOT/tests/image-runtime.py"
"$ROOT/tests/slack-thread-artifact.py"
"$ROOT/tests/artifact-path-safety.py"
# Which endpoint the company provider resolves to. Derived from the adapter
# table, not from a real request: it cannot prove the gateway accepts anything.
"$ROOT/tests/provider-route.py"

printf 'Static checks passed.\n'
printf 'These are static checks only: nothing here starts a container or calls the gateway.\n'
if ((${#LIMITED[@]})); then
  printf 'LIMITED VERIFICATION — not checked on this machine:\n'
  printf '  - %s\n' "${LIMITED[@]}"
fi
printf 'Nothing here proves Slack, the company gateway, STT or the cleanup cron work.\n'
printf 'scripts/deploy.sh only adds container-level checks; the rest is the manual\n'
printf 'release gate in the "%s" section of docs/runbook.md.\n' '人工 release gate'
