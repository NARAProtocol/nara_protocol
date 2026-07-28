import { readFile, readdir } from "node:fs/promises";
import { extname, join, resolve } from "node:path";
import process from "node:process";

const root = resolve(import.meta.dirname, "..");
const markdownLink = /!?\[[^\]]*\]\((https?:\/\/[^)\s]+)\)/g;
const links = new Set();

async function walk(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if ([".git", "node_modules", "verification"].includes(entry.name)) continue;
    const absolute = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(absolute));
    else if (extname(entry.name) === ".md") files.push(absolute);
  }
  return files;
}

for (const file of await walk(root)) {
  const content = await readFile(file, "utf8");
  for (const match of content.matchAll(markdownLink)) links.add(match[1]);
}

const failures = [];
const queue = [...links];
const workers = Array.from({ length: 4 }, async () => {
  while (queue.length > 0) {
    const url = queue.shift();
    try {
      const response = await fetch(url, {
        headers: { "user-agent": "NARA-public-docs-link-checker" },
        redirect: "follow",
        signal: AbortSignal.timeout(20_000),
      });
      if (response.status >= 400 && ![403, 429].includes(response.status)) {
        failures.push(`${response.status} ${url}`);
      }
    } catch (error) {
      failures.push(`${error.name}: ${url}`);
    }
  }
});
await Promise.all(workers);

if (failures.length > 0) {
  console.error("External link verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log(`External link verification passed (${links.size} links checked).`);
