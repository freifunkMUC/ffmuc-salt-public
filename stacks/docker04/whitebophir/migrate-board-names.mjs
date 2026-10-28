// One-time step for the v1 -> v2 upgrade. v2 only opens boards with a
// canonical name (for example lower case, no trailing "-") and does not find
// v1 files with other names. This copies board-<name>.json to
// board-<canonical>.json. The original files stay for a rollback to v1.
// Pass --apply to write files. Without it, the script only lists them:
//   docker run --rm --user 1000:1000 --entrypoint node \
//     -v /srv/docker/whitebophir/boards:/opt/app/server-data \
//     -v "$PWD/migrate-board-names.mjs:/tmp/m.mjs:ro" \
//     local/wbo:v2.18.25-node24.22.1 /tmp/m.mjs [--apply]
import { copyFile, readdir, stat, utimes } from "node:fs/promises";
import path from "node:path";
import { canonicalizeBoardName } from "/opt/app/client-data/js/board_name.js";

const dir = "/opt/app/server-data";
const apply = process.argv.includes("--apply");
const names = (await readdir(dir))
  .filter((f) => f.startsWith("board-") && f.endsWith(".json"))
  .map((f) => f.slice("board-".length, -".json".length));
const existing = new Set(names);
const targets = new Map();
for (const name of names) {
  const canonical = canonicalizeBoardName(name);
  if (canonical === name) continue;
  if (!canonical) {
    console.log(`skip (no canonical name): ${name}`);
    continue;
  }
  if (!targets.has(canonical)) targets.set(canonical, []);
  targets.get(canonical).push(name);
}
let copied = 0;
for (const [canonical, sources] of targets) {
  if (existing.has(canonical)) {
    console.log(`skip (target exists): ${sources.join(", ")} -> ${canonical}`);
    continue;
  }
  // Several v1 names can map to one v2 name. Take the newest board.
  const withTime = await Promise.all(
    sources.map(async (name) => ({
      name,
      mtime: (await stat(path.join(dir, `board-${name}.json`))).mtime,
    })),
  );
  withTime.sort((a, b) => b.mtime - a.mtime);
  const source = withTime[0];
  if (sources.length > 1) {
    console.log(`conflict: ${sources.join(", ")} -> ${canonical}, use ${source.name}`);
  }
  const from = path.join(dir, `board-${source.name}.json`);
  const to = path.join(dir, `board-${canonical}.json`);
  if (apply) {
    await copyFile(from, to);
    await utimes(to, source.mtime, source.mtime);
  }
  copied++;
}
console.log(`${apply ? "copied" : "would copy"} ${copied} boards`);
