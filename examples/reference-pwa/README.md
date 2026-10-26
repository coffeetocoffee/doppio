# Doppio Reference PWA

Official reference Progressive Web App demonstrating client-side offline evaluation, IndexedDB caching, and service worker background sync with Doppio.

## Features

- **Offline Evaluation:** Flag evaluation continues working seamlessly without internet connectivity using `@doppio/js` and local IndexedDB cache.
- **Service Worker Integration:** Uses `@doppio/sw` for background sync and offline static caching.
- **Dynamic Context Switcher:** Test flag decisions across different users, countries, and subscription tiers.
- **Deterministic Parity:** Evaluates flags with the same Zig WebAssembly core engine.

## Running

From the repository root:

```sh
node examples/reference-pwa/server.js
```

Open `http://localhost:3000/` in a browser.

To test offline behavior, toggle offline mode in your browser's Developer Tools (Network tab -> Offline).
