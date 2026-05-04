# posthog-clickhouse

ClickHouse server image with [PostHog](https://github.com/PostHog/posthog) configs baked in. Built for the [PostHog Railway template](https://railway.com/deploy/...).

PostHog requires a customized ClickHouse setup: cluster topology (`config.d/default.xml`), user profile flags (`users.xml`), UDFs for funnel queries (`user_defined_function.xml` + `user_scripts/`), and IDL schemas for Kafka-engine tables (`idl/`). PostHog ships these as files in their repo, expecting you to mount them via docker-compose. That doesn't work on Railway, where each service runs independently and doesn't share host paths. This image bakes them in at a pinned PostHog commit.

## Tags

```
ghcr.io/ikatsuba/posthog-clickhouse:<CH_VERSION>-<POSTHOG_SHA_SHORT>   # immutable
ghcr.io/ikatsuba/posthog-clickhouse:ch-<CH_VERSION>                    # rolling within CH version
ghcr.io/ikatsuba/posthog-clickhouse:latest                             # rolling
```

Pin to the immutable tag (`<CH_VERSION>-<SHA>`) in production templates.

## Build args

| Arg | Default | Notes |
|---|---|---|
| `CLICKHOUSE_VERSION` | `26.3.9.8` | Tag of `clickhouse/clickhouse-server:` base image. Match what upstream PostHog uses. |
| `POSTHOG_SHA` | (see Dockerfile) | Commit SHA of `PostHog/posthog` to pull configs from. |

## Updating PostHog

A scheduled GitHub Action (`.github/workflows/bump-posthog.yml`, Mondays 09:00 UTC) opens a PR bumping `POSTHOG_SHA` to the current `master` of upstream PostHog. Review the diff link in the PR, merge → image rebuilds and publishes.

To bump manually:

```bash
gh workflow run bump-posthog.yml
```

To update the ClickHouse version, edit `CLICKHOUSE_VERSION` in `Dockerfile` and push.

## License

MIT. PostHog configs are MIT (PostHog repo). ClickHouse base image is Apache 2.0.
