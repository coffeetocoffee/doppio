# Phase 2 backends

The control plane now supports optional external backends in addition to the
default SQLite store. Each backend is compile-gated so the default build has no
extra native dependencies.

## Build flags

| Flag | Links | Enables |
| --- | --- | --- |
| `-Dpostgres=true` | `libpq` | `Storage.openPostgres`, `--postgres` |
| `-Dvalkey=true` | `hiredis` | `SyncHub.enableValkey`, `--valkey` |

```sh
zig build -Dpostgres=true -Dvalkey=true
```

## Runtime flags

| Flag | Backend | Effect |
| --- | --- | --- |
| `--postgres "<conninfo>"` | Postgres | Connect + apply schema; selects `.postgres` |
| `--valkey <host>` | Valkey | Connect on port 6379; publish deltas to `doppio:flags` |
| `--clickhouse <url>` | ClickHouse | Forward exposure batches via `INSERT ... FORMAT JSONEachRow` |

ClickHouse needs no build flag (pure Zig, HTTP batching in `backends/clickhouse.zig`).

## Layout

- `src/backends/postgres.zig` — libpq facade, Postgres schema DDL
- `src/backends/valkey.zig` — hiredis facade, pub/sub + cache helpers
- `src/backends/clickhouse.zig` — HTTP batch builder + exposures DDL
- `src/backends/sigstore.zig` — audit sign/verify (wired into `storage.zig` audit chain)
- `docker-compose.yml` — postgres + valkey + clickhouse for integration testing

## Integration test

```sh
docker compose -f control-plane/docker-compose.yml up -d
zig build -Dpostgres=true -Dvalkey=true
./zig-out/bin/doppio-control-plane --postgres "host=localhost user=doppio password=doppio dbname=doppio" --valkey localhost --clickhouse http://localhost:8123
```
