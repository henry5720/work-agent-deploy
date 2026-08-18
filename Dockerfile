FROM ghcr.io/openabdev/openab:0.10.0-beta.3-claude@sha256:2b9fca58d898fdc5bceb2d48bcdd774287ece3352d6e3efbad7a213072232a89

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
USER node
