import test from "node:test";
import assert from "node:assert";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const exePath = path.resolve(__dirname, "../../zig-out/bin/doppio-control-plane.exe");
const port = 9087;
const base = `http://127.0.0.1:${port}`;

const adminToken =
  "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";

/** A second admin identity, so required-approval counts need two people. */
const reviewerToken =
  "eyJhbGciOiJub25lIn0.eyJzdWIiOiJyZXZpZXdlci1hbGljZSIsImV4cCI6MjAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";

const form = { "Content-Type": "application/x-www-form-urlencoded" };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const body = (params) => new URLSearchParams(params).toString();

test("Phase 1e v1 scope: change management, dependencies, blast radius, audit, experiments", async () => {
  const proc = spawn(exePath, ["--port", String(port)], { stdio: ["ignore", "pipe", "pipe"] });
  let procErr = "";
  proc.stderr.on("data", (d) => { procErr += d.toString(); });

  try {
    await sleep(600);

    // Session cookie.
    const login = await fetch(`${base}/admin/login`, {
      method: "POST", headers: form, body: body({ token: adminToken }), redirect: "manual",
    });
    assert.strictEqual(login.status, 303);
    const session = login.headers.get("set-cookie").split(";")[0];
    const auth = { Cookie: session };

    const reviewerLogin = await fetch(`${base}/admin/login`, {
      method: "POST", headers: form, body: body({ token: reviewerToken }), redirect: "manual",
    });
    const reviewerAuth = { Cookie: reviewerLogin.headers.get("set-cookie").split(";")[0] };

    // Seed a parent flag through the API so the dependency graph has an edge.
    const bearer = { Authorization: `Bearer ${adminToken}` };
    for (const [key, extra] of [["ui-parent", {}], ["ui-child", {}]]) {
      const created = await fetch(`${base}/api/v1/flags`, {
        method: "POST", headers: { ...form, ...bearer },
        body: JSON.stringify({ key, enabled: true, rollout_percentage: 100, ...extra }),
      });
      assert.strictEqual(created.status, 201);
    }

    const api = async (path) => (await fetch(`${base}${path}`, { headers: bearer })).json();

    // 1. Dashboard renders flag health and lifecycle signals.
    const dash = await fetch(`${base}/admin`, { headers: auth });
    assert.strictEqual(dash.status, 200);
    const dashHtml = await dash.text();
    assert.match(dashHtml, /Dashboard/);
    assert.match(dashHtml, /Lifecycle signals/);
    assert.match(dashHtml, /Audit integrity/);

    // 2. Flag detail page renders the dependency graph, blast radius, and history.
    const detail = await fetch(`${base}/admin/flags/ui-parent`, { headers: auth });
    const detailHtml = await detail.text();
    assert.strictEqual(detail.status, 200);
    assert.match(detailHtml, /<svg/);
    assert.match(detailHtml, /Dependencies/);
    assert.match(detailHtml, /History/);
    assert.match(detailHtml, /Rollback/);
    assert.match(detailHtml, /Blast radius/);
    assert.match(detailHtml, /Affected/);

    // 3. Required approvals gate the apply.
    const staged = await fetch(`${base}/admin/flags/ui-parent/edit`, {
      method: "POST", headers: { ...form, ...auth },
      body: body({
        key: "ui-parent", enabled: "off", rollout_percentage: "40",
        required_approvals: "2", scheduled_at: "",
      }),
    });
    assert.match(await staged.text(), /update staged/);

    // First approval records and does not apply.
    const first = await fetch(`${base}/admin/change-requests/cr-1/approve`, {
      method: "POST", headers: auth,
    });
    const firstHtml = await first.text();
    assert.match(firstHtml, /1\/2/);
    assert.match(firstHtml, /pending/);
    const stillOn = await api("/api/v1/flags/ui-parent");
    assert.strictEqual(stillOn.enabled, true);

    // Second approval, from a distinct admin, applies.
    await fetch(`${base}/admin/change-requests/cr-1/approve`, { method: "POST", headers: reviewerAuth });
    const afterApply = await api("/api/v1/flags/ui-parent");
    assert.strictEqual(afterApply.enabled, false);
    assert.strictEqual(afterApply.rollout_percentage, 40);

    // 4. Diff view shows the applied change and its detail.
    const crPage = await fetch(`${base}/admin/change-requests`, { headers: auth });
    const crHtml = await crPage.text();
    assert.match(crHtml, /applied/);
    assert.match(crHtml, /update ui-parent/);
    assert.match(crHtml, /cr-1/);

    // 5. Rollback restores the previous applied state.
    const rollback = await fetch(`${base}/admin/change-requests/ui-parent/rollback`, {
      method: "POST", headers: auth,
    });
    const rollbackText = await rollback.text();
    assert.match(rollbackText, /rollback/i);
    const rollbackMatch = rollbackText.match(/cr-\d+/);
    assert.ok(rollbackMatch, "the rollback banner names the staged change request");
    const rollbackId = rollbackMatch[0];

    await fetch(`${base}/admin/change-requests/${rollbackId}/approve`, { method: "POST", headers: auth });
    const reverted = await api("/api/v1/flags/ui-parent");
    assert.strictEqual(reverted.enabled, true, "rollback restored the previous state");
    assert.strictEqual(reverted.rollout_percentage, 100);

    // 6. Scheduled apply holds until the release time.
    const scheduled = await fetch(`${base}/admin/flags/ui-child/edit`, {
      method: "POST", headers: { ...form, ...auth },
      body: body({
        key: "ui-child", enabled: "off", rollout_percentage: "5",
        scheduled_at: "+3600",
      }),
    });
    assert.match(await scheduled.text(), /staged/);
    const scheduledId = (await (await fetch(`${base}/admin/change-requests`, { headers: auth })).text())
      .match(/cr-\d+/)[0];
    await fetch(`${base}/admin/change-requests/${scheduledId}/approve`, { method: "POST", headers: auth });
    const notYet = await api("/api/v1/flags/ui-child");
    assert.strictEqual(notYet.enabled, true, "scheduled change has not applied yet");
    const schedPage = await fetch(`${base}/admin/change-requests`, { headers: auth });
    assert.match(await schedPage.text(), /approved/);

    // 7. Audit log: search, filter, CSV export, and chain verification.
    const searched = await fetch(`${base}/admin/audit?q=CHANGE_REQUEST`, { headers: auth });
    assert.match(await searched.text(), /CHANGE_REQUEST_APPLIED/);

    const filtered = await fetch(`${base}/admin/audit?actor=admin-user`, { headers: auth });
    assert.match(await filtered.text(), /FLAG_UPDATE/);

    const noMatch = await fetch(`${base}/admin/audit?q=zzz-nothing`, { headers: auth });
    assert.match(await noMatch.text(), /No audit events match/);

    const verify = await fetch(`${base}/admin/audit/verify`, { headers: auth });
    assert.match(await verify.text(), /Chain verified across \d+ event/);

    const csv = await fetch(`${base}/admin/audit/export`, { headers: auth });
    assert.strictEqual(csv.status, 200);
    assert.match(csv.headers.get("content-type"), /text\/csv/);
    const csvText = await csv.text();
    const lines = csvText.trim().split("\n");
    assert.match(lines[0], /^id,action,target_type,target_id,actor,timestamp,hash$/);
    assert.ok(lines.length > 1, "CSV has data rows");
    for (const line of lines.slice(1)) {
      assert.strictEqual((line.match(/,/g) || []).length, 6, "seven CSV columns");
    }

    // 8. Experiment wizard: definition, power calculation, guardrails, lifecycle.
    const expCreate = await fetch(`${base}/admin/experiments`, {
      method: "POST", headers: { ...form, ...auth },
      body: body({
        hypothesis: "A shorter checkout increases completion rate",
        flag_key: "ui-parent",
        primary_metric: "completion_rate",
        baseline_rate: "0.32",
        mde: "0.03",
        power: "0.8",
        guardrails: "latency_p95_ms | 400\nerror_rate | 0.01",
      }),
    });
    assert.match(await expCreate.text(), /created: \d+ units per arm/);

    const expPage = await fetch(`${base}/admin/experiments`, { headers: auth });
    const expHtml = await expPage.text();
    assert.match(expHtml, /exp-1/);
    assert.match(expHtml, /per arm/);
    assert.match(expHtml, /running|draft/);

    const expDetail = await fetch(`${base}/admin/experiments/exp-1`, { headers: auth });
    const detailText = await expDetail.text();
    assert.match(detailText, /latency_p95_ms/);
    assert.match(detailText, /Guardrails/);
    assert.match(detailText, /Required sample/);
    assert.match(detailText, /Start running/);

    await fetch(`${base}/admin/experiments/exp-1/advance`, { method: "POST", headers: auth });
    const advanced = await fetch(`${base}/admin/experiments/exp-1`, { headers: auth });
    assert.match(await advanced.text(), /running/);

    // A badly formed experiment is refused.
    const badExp = await fetch(`${base}/admin/experiments`, {
      method: "POST", headers: { ...form, ...auth },
      body: body({
        hypothesis: "x", flag_key: "y", primary_metric: "z",
        baseline_rate: "1.5", mde: "0.01",
      }),
    });
    assert.match(await badExp.text(), /Baseline rate must be between 0 and 1/);

    // 9. Keyboard command palette is present and dependency-free.
    const flagsPage = await fetch(`${base}/admin/flags`, { headers: auth });
    const flagsHtml = await flagsPage.text();
    assert.match(flagsHtml, /id="palette"/);
    assert.match(flagsHtml, /htmx\.org/);
    assert.match(flagsHtml, /Ctrl|ctrl/);
  } catch (err) {
    if (procErr) console.error("Process stderr:", procErr);
    throw err;
  } finally {
    proc.kill();
  }
});
