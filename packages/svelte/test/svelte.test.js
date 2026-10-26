import test from "node:test";
import assert from "node:assert";
import { Doppio } from "@doppio/js";
import { createDoppioStore } from "../dist/index.js";

test("Svelte adapter: flag store emits value and updates on flag change", async () => {
  const client = await Doppio.init({
    flags: [
      {
        key: "svelte-flag",
        enabled: true,
        rolloutPercentage: 100,
        variations: [
          { key: "v1", value: "initial" },
          { key: "v2", value: "updated" },
        ],
        defaultVariation: 0,
      },
    ],
  });

  const store = createDoppioStore(client);
  const flagStore = store.flag("svelte-flag");

  let emitted = [];
  const unsub = flagStore.subscribe((val) => {
    emitted.push(val);
  });

  assert.strictEqual(emitted.length, 1);
  assert.strictEqual(emitted[0].enabled, true);
  assert.strictEqual(emitted[0].value, "initial");

  // Update flags on client
  await client.setFlags([
    {
      key: "svelte-flag",
      enabled: true,
      rolloutPercentage: 100,
      variations: [
        { key: "v1", value: "initial" },
        { key: "v2", value: "updated" },
      ],
      defaultVariation: 1,
    },
  ]);

  assert.strictEqual(emitted.length, 2);
  assert.strictEqual(emitted[1].value, "updated");

  unsub();
});
