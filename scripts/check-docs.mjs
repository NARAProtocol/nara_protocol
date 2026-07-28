import { readFile, readdir, stat } from "node:fs/promises";
import { dirname, extname, join, relative, resolve } from "node:path";
import process from "node:process";

const root = resolve(import.meta.dirname, "..");
const required = [
  "README.md",
  "SECURITY.md",
  "LEGAL.md",
  "CONTRIBUTING.md",
  "LICENSE",
  "docs/README.md",
  "docs/User_Guide.md",
  "docs/CURRENT_STATE.md",
  "docs/TOKEN_AND_ALLOCATION.md",
  "docs/Risk_Assessment.md",
  "docs/GLOSSARY.md",
];
const forbidden = [
  ["retired v3 token address", /0xE444[a-fA-F0-9]{36}/g],
  ["retired v3 engine name", /\bNARAEngineV2\b/g],
  ["obsolete mining route", /\/mine\b/g],
  ["guaranteed-return wording", /\bguaranteed (?:yield|return|profit)\b/gi],
  ["placeholder", /\b(?:TODO|TBD|FIXME)\b/g],
  ["ellipsis placeholder", /^\s*(?:\.\.\.|…)\s*$/gm],
];
const markdownLink = /!?\[[^\]]*\]\(([^)]+)\)/g;
const errors = [];
const canonicalToken = "0x65E247AA3aa9C0131b2984b894c3D24c41341D7A";

async function walk(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if ([".git", "node_modules"].includes(entry.name)) continue;
    const absolute = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(absolute));
    else files.push(absolute);
  }
  return files;
}

for (const path of required) {
  try {
    if (!(await stat(join(root, path))).isFile()) errors.push(`Missing required file: ${path}`);
  } catch {
    errors.push(`Missing required file: ${path}`);
  }
}

const files = await walk(root);
const textFiles = files.filter((file) => [".md", ".mjs", ".json", ""].includes(extname(file)));

for (const file of textFiles) {
  const content = await readFile(file, "utf8");
  const display = relative(root, file).replaceAll("\\", "/");

  if (extname(file) !== ".md") continue;
  for (const [label, pattern] of forbidden) {
    pattern.lastIndex = 0;
    if (pattern.test(content)) errors.push(`${display}: contains ${label}`);
  }

  for (const match of content.matchAll(markdownLink)) {
    const target = match[1].trim();
    if (
      target.startsWith("http://") ||
      target.startsWith("https://") ||
      target.startsWith("mailto:") ||
      target.startsWith("#")
    ) continue;
    const local = target.split("#", 1)[0];
    try {
      await stat(resolve(dirname(file), decodeURIComponent(local)));
    } catch {
      errors.push(`${display}: broken local link ${target}`);
    }
  }
}

for (const path of ["README.md", "docs/User_Guide.md", "docs/CURRENT_STATE.md"]) {
  const content = await readFile(join(root, path), "utf8");
  if (!content.includes(canonicalToken)) {
    errors.push(`${path}: missing canonical NARA v4 token address`);
  }
}

if (files.some((file) => relative(root, file).startsWith(`contracts${process.platform === "win32" ? "\\" : "/"}`))) {
  errors.push("contracts/: historical contract source must not return to the public docs repository");
}

if (errors.length > 0) {
  console.error("Documentation verification failed:");
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

console.log(`Documentation verification passed (${textFiles.length} files checked).`);
