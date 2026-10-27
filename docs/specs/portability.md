# SDK Portability Contract

## Core principles

1. **Pure JS core**: No Node.js-specific modules (`fs`, `net`, `crypto`, `http`). No `Buffer` (use `Uint8Array` + `btoa`/`atob` or `TextEncoder`).
2. **Injectable storage**: Storage is an interface `{ get(key), set(key, value), remove(key) }`. Host provides implementation (MemoryStorage, IndexedDbStorage, FileStorage, etc.).
3. **Injectable fetch**: Sync transport uses `fetchImpl` (default `globalThis.fetch`). Host may override.
4. **Injectable timers**: `setTimeout`/`setInterval`/`clearTimeout`/`clearInterval` are used via globals; for testing, hosts may inject. (Future: formalize as options.)
5. **No wall-clock in evaluation**: Evaluation is deterministic; `Date.now()` is only used for exposure timestamps, never for flag values.

## Host adapters

- **Node**: provides `fetch` (node 18+), `Buffer`-free binary handling, filesystem storage.
- **Browser**: provides `fetch`, `indexedDB`, `localStorage`.
- **Edge worker**: provides `fetch`, KV storage.

## Audit results (2026-10-27)

- `wasm_binary.ts`: uses `Buffer.from` with fallback to `atob` + `Uint8Array`. Acceptable (fallback present). Could be simplified to always use the atob path for true portability.
- `sync.ts`: uses `fetchImpl` (injectable) and `setTimeout`/`setInterval` (globals). Acceptable.
- `cache.ts`: guards `indexedDB` with `typeof` check. Acceptable.
- `client.ts`: uses `setTimeout(..., 0)` for async callback. Acceptable (global).

## Action items

- [ ] Simplify `wasm_binary.ts` to always use the `atob` + `Uint8Array` path (remove Buffer branch).
- [ ] Formalize timer injection in SyncClient options for deterministic testing.