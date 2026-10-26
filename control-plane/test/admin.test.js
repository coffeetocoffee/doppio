import test from "node:test";
import assert from "node:assert";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const exePath = path.resolve(__dirname, "../../zig-out/bin/doppio-control-plane.exe");
const port = 9094;
const base = `http://127.0.0.1:${port}`;

/** The admin JWT carries an "admin": true claim so the UI session accepts it. */
const adminToken =
  "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("admin UI: login gate, flag CRUD via change requests, segments, and console", async () => {
  const proc = spawn(exePath, ["--port", String(port)], { stdio: ["ignore", "pipe", "pipe"] });
  let procErr = "";
  proc.stderr.on("data", (d) => { procErr += d.toString(); });

  try {
    await sleep(600);

    // 1. Unauthenticated access shows the login page, never flag data.
    const gated = await fetch(`${base}/admin/flags`);
    assert.strictEqual(gated.status, 200);
    assert.match(gated.headers.get("content-type"), /text\/html/);
    const gatedHtml = await gated.text();
    assert.match(gatedHtml, /Admin session required/);
    assert.ok(!gatedHtml.includes("<table"));

    // 2. A bad token is rejected.
    const badLogin = await fetch(`${base}/admin/login`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ token: "not-a-real-token" }).toString(),
    });
    const badHtml = await badLogin.text();
    assert.match(badHtml, /Invalid or non-admin token/);

    // 3. A valid admin token gets a session cookie and a redirect.
    const login = await fetch(`${base}/admin/login`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ token: adminToken }).toString(),
      redirect: "manual",
    });
    assert.strictEqual(login.status, 303);
    assert.strictEqual(login.headers.get("location"), "/admin/flags");
    const cookie = login.headers.get("set-cookie");
    assert.ok(cookie && cookie.startsWith("doppio_admin="), "sets the admin cookie");
    const session = cookie.split(";")[0];

    // 4. The flags page renders with the nav and the HTMX app shell.
    const flagsPage = await fetch(`${base}/admin/flags`, { headers: { Cookie: session } });
    assert.strictEqual(flagsPage.status, 200);
    const flagsHtml = await flagsPage.text();
    assert.match(flagsHtml, /<title>/);
    assert.match(flagsHtml, /Feature flags/);
    assert.match(flagsHtml, /aria-current="page"/);
    assert.match(flagsHtml, /htmx\.org/, "ships the HTMX runtime");
    assert.match(flagsHtml, /id="flag-rows"/);

    // 5. Staging a create does not apply it.
    const stage = await fetch(`${base}/admin/flags`, {
      method: "POST",
      headers: { ...formHeaders(), Cookie: session },
      body: new URLSearchParams({ key: "ui-flag", enabled: "on", rollout_percentage: "75" }).toString(),
    });
    const stageHtml = await stage.text();
    assert.match(stageHtml, /create staged: create ui-flag/);
    assert.match(stageHtml, /cr-1/);

    const beforeApproval = await (await fetch(`${base}/api/v1/flags/ui-flag`)).json();
    assert.ok(beforeApproval.error, "flag is not live until approved");

    // 6. Approving applies it.
    const approve = await fetch(`${base}/admin/change-requests/cr-1/approve`, {
      method: "POST",
      headers: { Cookie: session },
    });
    const approveHtml = await approve.text();
    assert.match(approveHtml, /applied/);

    const afterApproval = await fetch(`${base}/api/v1/flags/ui-flag`, { headers: { Cookie: session } });
    const flagJson = await afterApproval.json();
    assert.strictEqual(flagJson.key, "ui-flag");
    assert.strictEqual(flagJson.enabled, true);
    assert.strictEqual(flagJson.rollout_percentage, 75);

    // 7. The change request list and audit log both reflect it.
    const crPage = await fetch(`${base}/admin/change-requests`, { headers: { Cookie: session } });
    const crHtml = await crPage.text();
    assert.match(crHtml, /ui-flag/);
    assert.match(crHtml, /applied/);

    const audit = await fetch(`${base}/admin/audit`, { headers: { Cookie: session } });
    const auditHtml = await audit.text();
    assert.match(auditHtml, /CHANGE_REQUEST_APPROVED/);
    assert.match(auditHtml, /FLAG_UPDATE/);

    // 8. Editing stages an update rather than mutating in place.
    const stageUpdate = await fetch(`${base}/admin/flags/ui-flag/edit`, {
      method: "POST",
      headers: { ...formHeaders(), Cookie: session },
      body: new URLSearchParams({ key: "ui-flag", enabled: "off", rollout_percentage: "10" }).toString(),
    });
    assert.match(await stageUpdate.text(), /update staged: update ui-flag/);
    const stillOn = await (await fetch(`${base}/api/v1/flags/ui-flag`, { headers: { Cookie: session } })).json();
    assert.strictEqual(stillOn.enabled, true, "still the old value until approved");

    // The table lists the newest request first, so first match is the update.
    const afterStage = await (await fetch(`${base}/admin/change-requests`, { headers: { Cookie: session } })).text();
    const updateId = afterStage.match(/cr-\d+/)?.[0];
    assert.ok(updateId && updateId !== "cr-1", "the update is a new change request");
    await fetch(`${base}/admin/change-requests/${updateId}/approve`, {
      method: "POST",
      headers: { Cookie: session },
    });
    const updated = await (await fetch(`${base}/api/v1/flags/ui-flag`, { headers: { Cookie: session } })).json();
    assert.strictEqual(updated.enabled, false);
    assert.strictEqual(updated.rollout_percentage, 10);

    // 9. Staging and approving a delete removes the flag.
    await fetch(`${base}/admin/flags/ui-flag/delete`, { method: "POST", headers: { Cookie: session } });
    const crPage2 = await (await fetch(`${base}/admin/change-requests`, { headers: { Cookie: session } })).text();
    const deleteId = crPage2.match(/cr-\d+/)?.[0];
    assert.ok(deleteId && deleteId !== updateId, "the delete is a new change request");
    await fetch(`${base}/admin/change-requests/${deleteId}/approve`, {
      method: "POST",
      headers: { Cookie: session },
    });
    const gone = await fetch(`${base}/api/v1/flags/ui-flag`, { headers: { Cookie: session } });
    assert.strictEqual(gone.status, 404);

    // 10. Segments: valid CEL is stored, malformed CEL is refused.
    const segCreate = await fetch(`${base}/admin/segments`, {
      method: "POST",
      headers: { ...formHeaders(), Cookie: session },
      body: new URLSearchParams({
        key: "enterprise-accounts",
        expression: 'account.plan == "enterprise"',
      }).toString(),
    });
    assert.match(await segCreate.text(), /created/);

    const segBad = await fetch(`${base}/admin/segments`, {
      method: "POST",
      headers: { ...formHeaders(), Cookie: session },
      body: new URLSearchParams({ key: "broken", expression: "this ((is not valid" }).toString(),
    });
    assert.match(await segBad.text(), /not valid CEL/);

    // 11. The console evaluates expressions the same way the SDKs do.
    const yes = await fetch(`${base}/admin/segments/console`, {
      method: "POST",
      headers: { ...formHeaders(), Cookie: session },
      body: new URLSearchParams({ expression: 'unit_id == "user-123"', unit_id: "user-123" }).toString(),
    });
    assert.match(await yes.text(), /TRUE/);

    const no = await fetch(`${base}/admin/segments/console`, {
      method: "POST",
      headers: { ...formHeaders(), Cookie: session },
      body: new URLSearchParams({ expression: 'unit_id == "someone-else"', unit_id: "user-123" }).toString(),
    });
    assert.match(await no.text(), /FALSE/);

    // Attributes make account/country style segments testable, and the echoed
    // attributes are HTML escaped.
    const attr = await fetch(`${base}/admin/segments/console`, {
      method: "POST",
      headers: { ...formHeaders(), Cookie: session },
      body: new URLSearchParams({
        expression: 'account.plan == "enterprise"',
        unit_id: "u-9",
        attributes: 'account.plan=enterprise, country=de',
      }).toString(),
    });
    const attrHtml = await attr.text();
    assert.match(attrHtml, /TRUE/);
    assert.match(attrHtml, /account\.plan = enterprise/);

    const attrMiss = await fetch(`${base}/admin/segments/console`, {
      method: "POST",
      headers: { ...formHeaders(), Cookie: session },
      body: new URLSearchParams({
        expression: 'account.plan == "starter"',
        unit_id: "u-9",
        attributes: "account.plan=enterprise",
      }).toString(),
    });
    assert.match(await attrMiss.text(), /FALSE/);

    // 12. The filter fragment narrows the flag table.
    const filtered = await fetch(`${base}/admin/frag/flags?q=zzz-no-match`, { headers: { Cookie: session } });
    assert.match(await filtered.text(), /No matching flags/);

    // 13. Logout-free session expiry: a bogus cookie falls back to the login page.
    const expired = await fetch(`${base}/admin/flags`, { headers: { Cookie: "doppio_admin=bogus" } });
    assert.match(await expired.text(), /Admin session required/);
  } catch (err) {
    if (procErr) console.error("Process stderr:", procErr);
    throw err;
  } finally {
    proc.kill();
  }
});

function formHeaders() {
  return { "Content-Type": "application/x-www-form-urlencoded" };
}
