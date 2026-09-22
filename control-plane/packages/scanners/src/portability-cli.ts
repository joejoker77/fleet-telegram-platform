// Run the portability lint outside the publish path — for auditing what is already in
// the catalogue, or for checking a skill before offering it.
//
//   tsx portability-cli.ts <owner-username> <skill-dir> [<skill-dir> ...]
//   tsx portability-cli.ts --json <owner> <dir>
//
// Same code as the publish path uses (portability.ts), deliberately: a second copy of
// these rules would drift from the one that actually runs, and then the audit and the
// warning would disagree about the same skill.
import path from "node:path";
import { portabilityLint, formatWarnings } from "./portability.js";

const argv = process.argv.slice(2);
const asJson = argv[0] === "--json";
const rest = asJson ? argv.slice(1) : argv;
const owner = rest[0];
const dirs = rest.slice(1);

if (!owner || dirs.length === 0) {
  console.error("usage: portability-cli.ts [--json] <owner-username> <skill-dir> [...]");
  process.exit(64);
}

const report = dirs.map((dir) => ({
  dir,
  name: path.basename(dir),
  warnings: portabilityLint(dir, owner),
}));

if (asJson) {
  console.log(JSON.stringify(report, null, 1));
} else {
  for (const r of report) {
    if (!r.warnings.length) {
      console.log(`${r.name}: portable — nothing found`);
      continue;
    }
    console.log(`${r.name}: ${r.warnings.length} thing(s) tied to one machine`);
    for (const line of formatWarnings(r.warnings)) console.log(`   ${line}`);
  }
}
