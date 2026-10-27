import { readFileSync } from "node:fs";
import { Doppio } from "../../packages/js/dist/index.js";

const fixture = JSON.parse(readFileSync(process.argv[2], "utf8"));
const doppio = await Doppio.init({ flags: fixture.flags });
const out = [];
for (const ctx of fixture.contexts) {
  for (const f of fixture.flags) {
    const r = await doppio.get(f.key, ctx);
    out.push({ flag: f.key, ctx: ctx.targetingKey, value: r.value, reason: r.reason });
  }
}
console.log(JSON.stringify(out));