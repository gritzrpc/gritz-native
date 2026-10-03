FROM ruby@sha256:c4428c90c4e80ee5848c31912969e73c9f48ac45ec45dfb5f76d1a821358771e

RUN apt-get update && apt-get install -y --no-install-recommends git libicu-dev ca-certificates iproute2 \
    && rm -rf /var/lib/apt/lists/*
COPY actions-runner-linux-arm64-2.337.0.tar.gz /tmp/actions-runner.tar.gz
COPY ghz /usr/local/bin/ghz
COPY ca.pem /etc/gritz-ca.pem
RUN mkdir -p /opt/actions-runner /opt/gritz-baselines \
    && tar -xzf /tmp/actions-runner.tar.gz -C /opt/actions-runner \
    && rm /tmp/actions-runner.tar.gz
ENV RUNNER_ALLOW_RUNASROOT=1 \
    SSL_CERT_FILE=/etc/gritz-ca.pem \
    GIT_SSL_CAINFO=/etc/gritz-ca.pem \
    NODE_EXTRA_CA_CERTS=/etc/gritz-ca.pem
WORKDIR /opt/actions-runner
ENTRYPOINT ["/opt/actions-runner/run.sh"]
