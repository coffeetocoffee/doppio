import test from "node:test";
import assert from "node:assert";
import { createApp } from "vue";
import { Doppio } from "@doppio/js";
import { createDoppio, DOPPIO_KEY } from "../dist/index.js";

test("Vue adapter: createDoppio plugin registers into Vue app", async () => {
  const client = await Doppio.init({
    flags: [{ key: "vue-test", enabled: true, rolloutPercentage: 100 }],
  });

  const app = createApp({ template: "<div>test</div>" });
  app.use(createDoppio(client));

  assert.strictEqual(app.config.globalProperties.$doppio, client);
});
