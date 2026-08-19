FROM ghcr.io/openabdev/openab:0.10.0-beta.3-claude@sha256:2b9fca58d898fdc5bceb2d48bcdd774287ece3352d6e3efbad7a213072232a89

# Bind mounts carry host ownership, so the container user must share the host
# user's uid/gid. Only /home/node and /usr/local/bin/openab are owned by the
# image's node user, so remapping is cheap.
ARG HOST_UID=1000
ARG HOST_GID=1000

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
RUN npm i -g @colbymchenry/codegraph@1.5.0
RUN if [ "$HOST_GID" != "1000" ]; then groupmod -g "$HOST_GID" node; fi \
    && if [ "$HOST_UID" != "1000" ]; then usermod -u "$HOST_UID" -g "$HOST_GID" node; fi \
    && chown -R "$HOST_UID:$HOST_GID" /home/node /usr/local/bin/openab
USER node
