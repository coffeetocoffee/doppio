import test from "node:test";
import assert from "node:assert";
import { registerServiceWorker, unregisterServiceWorker, createServiceWorkerScript } from "../dist/index.js";

test("Service worker: script generator produces valid sw bundle", () => {
  const script = createServiceWorkerScript();
  assert.ok(script.includes("doppio-sw-v1"));
  assert.ok(script.includes("DOPPIO_SAVE_CONFIG"));
  assert.ok(script.includes("DOPPIO_GET_CONFIG"));
});

test("Service worker: registerServiceWorker handles SSR/Node gracefully", async () => {
  const reg = await registerServiceWorker("/doppio-sw.js");
  assert.strictEqual(reg, null);
  const unreg = await unregisterServiceWorker();
  assert.strictEqual(unreg, false);
});
