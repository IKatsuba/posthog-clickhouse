# https://github.com/IKatsuba/posthog-clickhouse
# syntax=docker/dockerfile:1.7

# PostHog ClickHouse image for Railway template.
# Pulls cluster topology, user profiles, UDFs, IDL schemas and user_scripts
# from upstream PostHog at a pinned commit SHA, and bakes them into
# the official ClickHouse server image.

ARG CLICKHOUSE_VERSION=26.3.9.8
ARG POSTHOG_SHA=70c912d5b7b94cf8930e376986b1e4bedb1f4bfb

# ---------- stage 1: fetch PostHog config files ----------
FROM alpine/git:2.45.2 AS source
ARG POSTHOG_SHA
WORKDIR /tmp
RUN git clone --filter=blob:none --no-checkout https://github.com/PostHog/posthog.git posthog \
 && cd posthog \
 && git checkout ${POSTHOG_SHA} -- \
        docker/clickhouse \
        posthog/idl \
        posthog/user_scripts

# ---------- stage 2: bake into ClickHouse server ----------
FROM clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}

LABEL org.opencontainers.image.source="https://github.com/IKatsuba/posthog-clickhouse"
LABEL org.opencontainers.image.description="ClickHouse for PostHog self-hosted on Railway. Pinned PostHog configs."
LABEL org.opencontainers.image.licenses="MIT"

# Cluster topology (remote_servers: posthog, posthog_single_shard, etc.)
COPY --from=source /tmp/posthog/docker/clickhouse/config.d/default.xml \
                   /etc/clickhouse-server/config.d/default.xml

# User profiles (compatibility=25.8, allow_nondeterministic_mutations, ...)
COPY --from=source /tmp/posthog/docker/clickhouse/users.xml \
                   /etc/clickhouse-server/users.xml

# UDF declarations (aggregate_funnel et al.)
COPY --from=source /tmp/posthog/docker/clickhouse/user_defined_function.xml \
                   /etc/clickhouse-server/user_defined_function.xml

# Executable scripts the UDFs call (Python aggregators)
COPY --from=source /tmp/posthog/posthog/user_scripts \
                   /var/lib/clickhouse/user_scripts

# IDL schemas for Kafka-engine tables
COPY --from=source /tmp/posthog/posthog/idl \
                   /idl

# Cluster topology in PostHog's compose hardcodes host=clickhouse (their service name).
# Replace with localhost so single-node deployments (Railway, bare docker run) start clean.
# In a multi-node setup, override config.d/default.xml at runtime via volume mount.
RUN sed -i 's|<host>clickhouse</host>|<host>localhost</host>|g' \
        /etc/clickhouse-server/config.d/default.xml

# Listen on IPv6 (and IPv4 via dual-stack) — Railway's private network is IPv6-only.
RUN printf '<clickhouse><listen_host>::</listen_host></clickhouse>\n' \
      > /etc/clickhouse-server/config.d/listen.xml

# Make user_scripts executable (host bind mounts already are; built-in COPY needs explicit)
RUN chmod -R +x /var/lib/clickhouse/user_scripts && \
    chown -R clickhouse:clickhouse /var/lib/clickhouse/user_scripts /idl

# Ports inherited from base image (8123 HTTP, 9000 native)
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:8123/ping || exit 1

