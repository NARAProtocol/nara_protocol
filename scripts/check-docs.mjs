import { createHash } from "node:crypto";
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
  "docs/HISTORY.md",
  "verification/README.md",
  "verification/deployment.json",
  "verification/release.json",
  "verification/engine-constructor.json",
];
const forbidden = [
  ["retired v3 token address", /0xE444[a-fA-F0-9]{36}/g],
  ["retired v3 engine name", /\bNARAEngineV2\b/g],
  ["obsolete mining route", /\/mine\b/g],
  ["guaranteed-return wording", /\bguaranteed (?:yield|return|profit)\b/gi],
  ["private engineering repository link", /github\.com\/NARAProtocol\/nara_protocol_v4/gi],
  ["placeholder", /\b(?:TODO|TBD|FIXME)\b/g],
  ["ellipsis placeholder", /^\s*(?:\.\.\.|\u2026)\s*$/gm],
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

const deployment = JSON.parse(
  await readFile(join(root, "verification", "deployment.json"), "utf8"),
);
const release = JSON.parse(
  await readFile(join(root, "verification", "release.json"), "utf8"),
);
if (deployment.chainId !== 8453 || deployment.network !== "base") {
  errors.push("verification/deployment.json: expected Base chain ID 8453");
}
if (deployment.contracts?.token?.address !== canonicalToken) {
  errors.push("verification/deployment.json: canonical token address mismatch");
}
if (deployment.sourceCommit !== release.sourceCommit) {
  errors.push("verification package: deployment and release commits disagree");
}
if (deployment.contracts?.engine?.blockscoutSourceVerified !== true) {
  errors.push("verification/deployment.json: engine explorer verification missing");
}
const engineConstructor = JSON.parse(
  await readFile(join(root, "verification", "engine-constructor.json"), "utf8"),
);
if (
  engineConstructor.address !== deployment.contracts?.engine?.address ||
  engineConstructor.creationCodeMatchedLaunchCalldata !== true ||
  engineConstructor.predictedAddressMatchedDeployment !== true
) {
  errors.push("verification/engine-constructor.json: engine evidence mismatch");
}
if (release.sourceCommit !== "3215b69a1154b9c30957cd8d875b636dedc9d0ca") {
  errors.push("verification/release.json: unexpected deployed source commit");
}
if (Object.keys(deployment.contracts ?? {}).length !== 8) {
  errors.push("verification/deployment.json: expected eight deployed NARA contracts");
}
for (const [name, contract] of Object.entries(deployment.contracts ?? {})) {
  if (!/^0x[a-fA-F0-9]{40}$/.test(contract.address ?? "")) {
    errors.push(`verification/deployment.json: invalid ${name} address`);
  }
  if (!/^0x[a-fA-F0-9]{64}$/.test(contract.runtimeCodeHash ?? "")) {
    errors.push(`verification/deployment.json: invalid ${name} runtime code hash`);
  }
  if (!/^[a-f0-9]{64}$/.test(contract.runtimeCodeSha256 ?? "")) {
    errors.push(`verification/deployment.json: invalid ${name} runtime SHA-256`);
  }
}

const sha256 = (content) => createHash("sha256").update(content).digest("hex");
for (const source of release.sources ?? []) {
  const content = await readFile(join(root, "verification", "sources", source.path), "utf8");
  if (sha256(content.replaceAll("\r\n", "\n")) !== source.sha256) {
    errors.push(`verification source hash mismatch: ${source.path}`);
  }
}
for (const entrypoint of release.entrypoints ?? []) {
  const artifact = JSON.parse(await readFile(join(root, entrypoint.artifact), "utf8"));
  if (sha256(JSON.stringify(artifact)) !== entrypoint.sha256) {
    errors.push(`verification artifact hash mismatch: ${entrypoint.contract}`);
  }
}

for (const path of ["README.md", "docs/User_Guide.md", "docs/CURRENT_STATE.md"]) {
  const content = await readFile(join(root, path), "utf8");
  if (!content.includes(canonicalToken)) {
    errors.push(`${path}: missing canonical NARA v4 token address`);
  }
}

const tokenDocumentation = await readFile(
  join(root, "docs", "TOKEN_AND_ALLOCATION.md"),
  "utf8",
);
for (const requiredFact of ["100,000 NARA", "0.10%", "ERC-3156", "temporarily"]) {
  if (!tokenDocumentation.includes(requiredFact)) {
    errors.push(`docs/TOKEN_AND_ALLOCATION.md: missing flash-mint fact ${requiredFact}`);
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
