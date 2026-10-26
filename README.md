# Doppio ☕

> Double-shot A/B comparisons — feature flags & experimentation platform.

[![v1.0](https://img.shields.io/badge/release-v1.0-blue)](https://github.com/coffeetocoffee/doppio/releases/tag/v1.0)

## What is it?

Doppio is a feature-flag and experimentation platform with SDKs in JS, Python, and Go, plus a Zig control plane. Evaluate flags locally, sync deltas in real time, and track exposures — all from one core.

## Packages

| Package | Path | Status |
|---|---|---|
| JS SDK | `packages/js` | ✅ |
| Python SDK | `packages/py` | ✅ |
| Go SDK | `packages/go` | ✅ |
| Control plane | `control-plane` | ✅ |

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

## License

Apache-2.0