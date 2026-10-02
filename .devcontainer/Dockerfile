FROM ruby:3.4-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl procps smem jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY tool-versions install-tools.sh /tmp/
RUN sh /tmp/install-tools.sh
