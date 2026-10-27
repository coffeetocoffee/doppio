#!/usr/bin/env node
const fs = require("fs");
const { execSync } = require("child_process");
const args = process.argv.slice(2);
const get = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i+1] : null; };
const src = get("--source") || "ld";
const inputFile = get("--file");
const outDir = get("--out") || "./imported";
const dryRun = args.includes("--dry-run");
const scripts = {
  ld: "ld_to_doppio.py", unleash: "unleash_to_doppio.py",
  growthbook: "growthbook_to_doppio.py", flagsmith: "flagsmith_to_doppio.py",
};
if (!scripts[src]) { console.error("Unknown source:", src); process.exit(1); }

if (!inputFile) { console.error("Usage: importer --file <export.json> --out <dir> [--dry-run]"); process.exit(1); }

const data = JSON.parse(fs.readFileSync(inputFile, "utf8"));
const flags = Array.isArray(data) ? data : (data.items || []);

// delegate to python converter
const os = require("os"), path = require("path");
const td = os.tmpdir();
const tmpIn = path.join(td, "ld_in.json"), tmpFlags = path.join(td, "doppio_flags.json"), tmpReport = path.join(td, "report.json"), tmpMd = path.join(td, "report.md");
fs.writeFileSync(tmpIn, JSON.stringify(flags));
const script = require("path").join(__dirname, "..", "migrate", scripts[src]);
execSync(`python "${script}" "${tmpIn}" "${tmpFlags}" "${tmpReport}" "${tmpMd}"`);

const converted = JSON.parse(fs.readFileSync(tmpFlags, "utf8"));
const report = JSON.parse(fs.readFileSync(tmpReport, "utf8"));
let md = "";
try { md = fs.readFileSync(tmpMd, "utf8"); } catch (e) {}

if (dryRun) {
  console.log(md);
  console.log("\nDry run: no files written.");
  process.exit(report.manual.length > 0 ? 2 : 0);
}

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(`${outDir}/flags.json`, JSON.stringify(converted, null, 2));
fs.writeFileSync(`${outDir}/report.json`, JSON.stringify(report, null, 2));
fs.writeFileSync(`${outDir}/report.md`, md);
console.log(`Wrote ${converted.length} flags to ${outDir}/`);
console.log(`clean=${report.clean.length} deviation=${report.deviation.length} manual=${report.manual.length}`);
process.exit(report.manual.length > 0 ? 2 : 0);