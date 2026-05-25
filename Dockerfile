# https://github.com/IKatsuba/posthog-clickhouse
# syntax=docker/dockerfile:1.7

# PostHog ClickHouse image for Railway template.
# Pulls cluster topology, user profiles, UDFs, IDL schemas and user_scripts
# from upstream PostHog at a pinned commit SHA, and bakes them into
# the official ClickHouse server image.

ARG CLICKHOUSE_VERSION=26.3.9.8
ARG POSTHOG_SHA=edd553e0af1812689d4ba970e12b47b37d2118c8

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
# Read the externally-reachable hostname from CLICKHOUSE_INTERNAL_HOST so the
# `system.clusters` entries point clients (Web, Worker, Migrate) at the right
# address. Default to `localhost` when the env var is unset (single-node /
# `docker run` with no networking).
RUN sed -i 's|<host>clickhouse</host>|<host from_env="CLICKHOUSE_INTERNAL_HOST"/>|g' \
        /etc/clickhouse-server/config.d/default.xml

# Grant the runtime-created posthog user access to named_collections — PostHog
# defines msk_cluster / warpstream_* and ClickHouse 26.x requires an explicit
# NAMED COLLECTION grant to use them in Storage = Kafka tables.
RUN cat > /etc/clickhouse-server/users.d/posthog-named-collections.xml <<'XML'
<clickhouse>
    <users>
        <posthog>
            <access_management>1</access_management>
            <named_collection_control>1</named_collection_control>
            <show_named_collections>1</show_named_collections>
            <show_named_collections_secrets>1</show_named_collections_secrets>
        </posthog>
    </users>
</clickhouse>
XML

# Listen on IPv6 (and IPv4 via dual-stack) — Railway's private network is IPv6-only.
RUN printf '<clickhouse><listen_host>::</listen_host></clickhouse>\n' \
      > /etc/clickhouse-server/config.d/listen.xml

# PostHog migration 0159 creates a view over system.crash_log; ClickHouse
# only materialises that table on first crash. Run a CREATE TABLE IF NOT
# EXISTS via <startup_scripts> on every server start so the migration
# succeeds even on volumes that already skipped initdb.d.
RUN cat > /etc/clickhouse-server/config.d/startup-scripts.xml <<'XML'
<clickhouse>
    <startup_scripts>
        <scripts>
            <query>
                CREATE TABLE IF NOT EXISTS system.crash_log (
                    hostname LowCardinality(String),
                    event_date Date,
                    event_time DateTime,
                    timestamp_ns UInt64,
                    signal Int32,
                    thread_id UInt64,
                    query_id String,
                    trace Array(UInt64),
                    trace_full Array(String),
                    version String,
                    revision UInt32,
                    build_id String
                ) ENGINE = MergeTree
                PARTITION BY toYYYYMM(event_date)
                ORDER BY (event_date, event_time)
            </query>
        </scripts>
    </startup_scripts>
</clickhouse>
XML

# Embedded clickhouse-keeper. PostHog requires a Zookeeper-compatible quorum
# for Replicated* tables; running keeper inside the same process avoids a
# second container in single-node Railway deployments.
RUN cat > /etc/clickhouse-server/config.d/keeper.xml <<'XML'
<clickhouse>
    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>1</server_id>
        <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>warning</raft_logs_level>
        </coordination_settings>
        <raft_configuration>
            <server>
                <id>1</id>
                <hostname>localhost</hostname>
                <port>9234</port>
            </server>
        </raft_configuration>
    </keeper_server>
    <zookeeper>
        <node>
            <host>localhost</host>
            <port>9181</port>
        </node>
    </zookeeper>
</clickhouse>
XML

# Make user_scripts executable (host bind mounts already are; built-in COPY needs explicit)
RUN chmod -R +x /var/lib/clickhouse/user_scripts && \
    chown -R clickhouse:clickhouse /var/lib/clickhouse/user_scripts /idl

# Ports inherited from base image (8123 HTTP, 9000 native)
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:8123/ping || exit 1

