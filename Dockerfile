# Base image 與所有版本的正本是 config/versions.env，經 scripts/compose.sh 帶進來。
# 這裡故意不給 ARG 預設值：沒有走 compose.sh 就 build 不起來，避免出現第二份版本。
ARG OPENAB_IMAGE
FROM ${OPENAB_IMAGE}

ARG OPENAB_AGENT_RUNTIME
ARG OPENCODE_VERSION
ARG OMO_VERSION
ARG CODEGRAPH_VERSION
ARG CLAUDE_AGENT_ACP_VERSION
ARG CLAUDE_CODE_VERSION
ARG DOCLING_VERSION

# Bind mounts carry host ownership, so the container user must share the host
# user's uid/gid. Only /home/node and /usr/local/bin/openab are owned by the
# image's node user, so remapping is cheap.
ARG HOST_UID=1000
ARG HOST_GID=1000

USER root
# git：-opencode base image（node:22-trixie-slim）沒有 git，但唯讀 snapshot 偵察
# 全靠 `git show origin/<branch>:<path>` 這類指令。python3：slack-list 需要。
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl git libxcb1 python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -c 'import sys; assert (3, 10) <= sys.version_info[:2] < (3, 14), sys.version' \
    && python3 -m pip install --no-cache-dir --break-system-packages "docling==${DOCLING_VERSION}" \
    && python3 -c 'import docling; import docling.document_converter'
ENV DOCLING_ARTIFACTS_PATH=/opt/docling-models
RUN mkdir -p /opt/docling-models \
    && docling-tools models download layout tableformer --output-dir /opt/docling-models \
    && python3 -c 'from pathlib import Path; p=Path("/opt/docling-models"); assert p.is_dir() and any(p.iterdir()), "Docling model download produced no artifacts"' \
    && chmod -R a+rX,a-w /opt/docling-models \
    && chown -R root:root /opt/docling-models
USER node
RUN python3 -c 'from pathlib import Path; import os; p=Path("/opt/docling-models"); assert p.is_dir() and any(p.iterdir()); assert all(os.access(item, os.R_OK | (os.X_OK if item.is_dir() else 0)) for item in p.rglob("*")), "Docling artifacts are not readable by node"'
USER root
RUN npm i -g "@colbymchenry/codegraph@${CODEGRAPH_VERSION}"
# OMO 的 Claude Code specialist 直接執行這個已固定版本的 binary，不用 npx
# 在 runtime 下載未審核的套件。Claude rollback 也共用同一份安裝。
RUN npm i -g "@agentclientprotocol/claude-agent-acp@${CLAUDE_AGENT_ACP_VERSION}"
RUN npm i -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
ENV CLAUDE_AGENT_ACP_VERSION=${CLAUDE_AGENT_ACP_VERSION} \
    CLAUDE_AGENT_ACP_BIN=/usr/local/bin/claude-agent-acp \
    CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} \
    CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude

# OpenCode 由 base image 安裝並固定版本，所以這裡只驗證它等於 versions.env 記的那一版：
# digest 換了卻忘了更新 OPENCODE_VERSION 會直接 build 失敗，而不是安靜地跑到別的版本。
# OMO 是 OpenCode plugin，用同一份 pin 裝成 global package，讓 runtime 不必上網抓 plugin。
# Claude ACP specialist 直接使用 image 內固定版本的 adapter。
RUN set -eu; \
    if [ "$OPENAB_AGENT_RUNTIME" = "opencode" ]; then \
      opencode --version | grep -qF "$OPENCODE_VERSION" \
        || { echo "opencode in base image does not match OPENCODE_VERSION=$OPENCODE_VERSION" >&2; exit 1; }; \
      npm i -g "oh-my-opencode-slim@${OMO_VERSION}"; \
    fi
RUN test -x "$CLAUDE_AGENT_ACP_BIN" \
    && test "$(command -v claude-agent-acp)" = "$CLAUDE_AGENT_ACP_BIN" \
    && npm ls -g --depth=0 "@agentclientprotocol/claude-agent-acp@${CLAUDE_AGENT_ACP_VERSION}" >/dev/null \
    || { echo "the pinned Claude ACP adapter is missing or mismatched" >&2; exit 1; }
RUN test -x /usr/local/bin/claude \
    && claude --version | grep -qF "$CLAUDE_CODE_VERSION" \
    || { echo "the pinned Claude Code CLI is missing or mismatched" >&2; exit 1; }

# 生圖／改圖的唯一入口。它只用 Python 3 stdlib。
# root 擁有、0755：agent 可以執行，不能改寫（rootfs 本來就是唯讀的，這是第二層）。
COPY agents/bin/company-image /usr/local/bin/company-image
COPY agents/bin/slack-thread-artifact /usr/local/bin/slack-thread-artifact
COPY agents/bin/parse-document /usr/local/bin/parse-document
RUN chmod 0755 /usr/local/bin/company-image \
    && chown root:root /usr/local/bin/company-image \
    && chmod 0755 /usr/local/bin/slack-thread-artifact \
    && chown root:root /usr/local/bin/slack-thread-artifact \
    && chmod 0755 /usr/local/bin/parse-document \
    && chown root:root /usr/local/bin/parse-document \
    && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'

# OpenCode 有兩個必須可寫的目錄：OPENCODE_CONFIG_DIR（/home/node/.config/opencode）
# 與它自己的 state root /home/node/.opencode，兩邊都會寫 `.gitignore` 與 state。
# compose 各掛一個可寫的 named volume，設定正本只用單檔唯讀疊在 config dir 上。
# 空的 named volume 會沿用 mount point 在 image 內的 ownership，目錄不存在就會變成
# root:root，node 寫不進去 —— 所以先建好，讓下面的 chown -R 一起接手。
# Claude Code 的 credential/state named volume 也會從這個 mount point 繼承
# ownership；少建這個目錄時 fresh volume 會是 root:root，node 無法登入或寫 state。
RUN mkdir -p /home/node/.claude /home/node/.config/opencode /home/node/.opencode

RUN if [ "$HOST_GID" != "1000" ]; then groupmod -g "$HOST_GID" node; fi \
    && if [ "$HOST_UID" != "1000" ]; then usermod -u "$HOST_UID" -g "$HOST_GID" node; fi \
    && chown -R "$HOST_UID:$HOST_GID" /home/node /usr/local/bin/openab
USER node
RUN company-image --help >/dev/null \
    && slack-thread-artifact --help >/dev/null \
    && parse-document --help >/dev/null
