# Doppio ☕

> Double-shot A/B comparisons — a feature-flag & experimentation platform.

[![v2.9.3](https://img.shields.io/badge/release-v2.9.3-blue)](https://github.com/coffeetocoffee/doppio/releases/tag/v2.9.3)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

Evaluate flags locally, sync deltas in real time, track exposures — one core, many SDKs.

## Packages

| Package | Path | Status |
|---|---|---|
| JS SDK | `packages/js` | ✅ |
| Python SDK | `packages/py` | ✅ |
| Go SDK | `packages/go` | ✅ |
| .NET SDK | `packages/dotnet` | 🚧 |
| Kotlin SDK | `packages/kotlin` | 🚧 |
| Control plane (Zig) | `control-plane` | ✅ |

## Quick start

```bash
npm install
npm run build
npm test
```

Python SDK:

```bash
cd packages/py && pip install -e . && python -m pytest tests
```

Go SDK:

```bash
cd packages/go && go test ./...
```

Control plane:

```bash
cd control-plane && zig build -Dvalkey -Dpostgres
./zig-out/bin/doppio-control-plane --port 8080
```

## Highlights

- ⚡ Local flag evaluation with rule-based targeting
- 🔄 Real-time delta sync (SSE, WebSocket, long-poll)
- 📊 Exposure tracking with ClickHouse forwarding
- 🗄️ SQLite / Postgres (HA primary+replica) / Valkey (sentinel + cluster scaffold)
- 🔐 Casbin-backed admin auth

## License

Apache-2.0