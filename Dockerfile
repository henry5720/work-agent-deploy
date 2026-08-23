# Base image 與所有版本的正本是 config/versions.env，經 scripts/compose.sh 帶進來。
# 這裡故意不給 ARG 預設值：沒有走 compose.sh 就 build 不起來，避免出現第二份版本。
ARG OPENAB_IMAGE
FROM ${OPENAB_IMAGE}

ARG OPENAB_AGENT_RUNTIME
ARG OPENCODE_VERSION
ARG OMO_VERSION
ARG CODEGRAPH_VERSION

# Bind mounts carry host ownership, so the container user must share the host
# user's uid/gid. Only /home/node and /usr/local/bin/openab are owned by the
# image's node user, so remapping is cheap.
ARG HOST_UID=1000
ARG HOST_GID=1000

USER root
# git：-opencode base image（node:22-trixie-slim）沒有 git，但唯讀 snapshot 偵察
# 全靠 `git show origin/<branch>:<path>` 這類指令。python3：slack-list 需要。
RUN apt-get update \
    && apt-get install -y --no-install-recommends git python3 \
    && rm -rf /var/lib/apt/lists/*
RUN npm i -g "@colbymchenry/codegraph@${CODEGRAPH_VERSION}"

# OpenCode 由 base image 安裝並固定版本，所以這裡只驗證它等於 versions.env 記的那一版：
# digest 換了卻忘了更新 OPENCODE_VERSION 會直接 build 失敗，而不是安靜地跑到別的版本。
# OMO 是 OpenCode plugin，用同一份 pin 裝成 global package，讓 runtime 不必上網抓 plugin。
# Claude ACP rollback image 沒有 opencode，整段跳過，改驗 claude-agent-acp 存在。
RUN set -eu; \
    if [ "$OPENAB_AGENT_RUNTIME" = "opencode" ]; then \
      opencode --version | grep -qF "$OPENCODE_VERSION" \
        || { echo "opencode in base image does not match OPENCODE_VERSION=$OPENCODE_VERSION" >&2; exit 1; }; \
      npm i -g "oh-my-opencode-slim@${OMO_VERSION}"; \
    else \
      command -v claude-agent-acp >/dev/null \
        || { echo "claude-agent-acp missing from the $OPENAB_AGENT_RUNTIME image" >&2; exit 1; }; \
    fi

# 生圖／改圖的唯一入口。兩個 variant 都從這份 Dockerfile 建，所以 Claude ACP
# rollback 拿到的是同一支 CLI，不會少掉生圖路徑。它只用 Python 3 stdlib。
# root 擁有、0755：agent 可以執行，不能改寫（rootfs 本來就是唯讀的，這是第二層）。
COPY agents/bin/company-image /usr/local/bin/company-image
COPY agents/bin/slack-thread-artifact /usr/local/bin/slack-thread-artifact
RUN chmod 0755 /usr/local/bin/company-image \
    && chown root:root /usr/local/bin/company-image \
    && chmod 0755 /usr/local/bin/slack-thread-artifact \
    && chown root:root /usr/local/bin/slack-thread-artifact \
    && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    && company-image --help >/dev/null \
    && slack-thread-artifact --help >/dev/null

# OpenCode 要在 OPENCODE_CONFIG_DIR 內寫 `.gitignore` 與 state，compose 因此把一個
# 可寫的 named volume 掛在 /home/node/.config/opencode，設定正本只用單檔唯讀疊上去。
# 空的 named volume 會沿用 mount point 在 image 內的 ownership，目錄不存在就會變成
# root:root，node 寫不進去 —— 所以先建好，讓下面的 chown -R 一起接手。
RUN mkdir -p /home/node/.config/opencode

RUN if [ "$HOST_GID" != "1000" ]; then groupmod -g "$HOST_GID" node; fi \
    && if [ "$HOST_UID" != "1000" ]; then usermod -u "$HOST_UID" -g "$HOST_GID" node; fi \
    && chown -R "$HOST_UID:$HOST_GID" /home/node /usr/local/bin/openab
USER node
