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
  "docs/ROADMAP.md",
  "docs/ROADMAP_EVIDENCE.md",
  "docs/ROADMAP_EVIDENCE.json",
  "verification/README.md",
  "verification/deployment.json",
  "verification/release.json",
  "verification/engine-constructor.json",
];
const forbidden = [
  ["retired v3 token address", /0xE444[a-fA-F0-9]{36}/g],
  ["retired Stage A token address", /0x65E247AA3aa9C0131b2984b894c3D24c41341D7A/gi],
  ["superseded baskets documentation commit", /bacc890004f4ca4fddb49854a7f5670312055a16/gi],
  ["superseded monitor documentation commit", /e99fdeeb5783a88209a7fceb56ac32ed3f50ec84/gi],
  ["retired v3 engine name", /\bNARAEngineV2\b/g],
  ["obsolete mining route", /\/mine\b/g],
  ["guaranteed-return wording", /\bguaranteed (?:yield|return|profit)\b/gi],
  ["private engineering repository link", /github\.com\/NARAProtocol\/nara_protocol_v4/gi],
  ["placeholder", /\b(?:TODO|TBD|FIXME)\b/g],
  ["ellipsis placeholder", /^\s*(?:\.\.\.|\u2026)\s*$/gm],
];
const markdownLink = /!?\[[^\]]*\]\(([^)]+)\)/g;
const errors = [];
const canonicalToken = "0xB6333F5D4cEd8dffA80F3F13697D6aA3BB3f19c1";
const canonicalPool = "0x83edced1f39e6adf7469cd718eeb409824d948959263408d4cfb6e745c8db464";
const positionNft = "0xCcBD8c59664958636369F8fe24B927aEBc3DF7cC";
const positionFinalization = "0xfb83cb4cb4b8a2c30216f46be69b519628ad74259795806e30d158a7736c6e8f";
const protocolDocsCommit = "dae88079dd336e22bdefde6f45e3b01389d554cb";
const basketsDocsCommit = "2213f4a7e9fe3af984fc4b157d92169c91b015a0";
const monitorDocsCommit = "4a96f7b7186a65b33366271128da8db230c9dd2e";

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
if (deployment.contracts?.engine?.basescanSourceVerified !== true) {
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
if (release.sourceCommit !== "027af3f06bbe6dea2c187dfd8062e50c228f1c35") {
  errors.push("verification/release.json: unexpected deployed source commit");
}
if (
  deployment.status !== "pool-activated-compounder-validated" ||
  deployment.pool?.registered !== true ||
  deployment.pool?.initialized !== true ||
  deployment.pool?.liquiditySeeded !== true
) {
  errors.push("verification/deployment.json: canonical pool activation evidence missing");
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

for (const path of [
  "README.md",
  "docs/README.md",
  "docs/User_Guide.md",
  "docs/CURRENT_STATE.md",
]) {
  const content = await readFile(join(root, path), "utf8");
  if (!/technical live testing/i.test(content)) {
    errors.push(`${path}: missing technical-live-testing warning`);
  }
}

const readme = await readFile(join(root, "README.md"), "utf8");
for (const requiredFact of [
  "not public product availability",
  "jurisdiction-specific qualified legal review is evidenced here",
  "Position NFT",
  "consumer integration remains unavailable",
]) {
  if (!readme.includes(requiredFact)) {
    errors.push(`README.md: missing public-state fact ${requiredFact}`);
  }
}

const currentState = await readFile(join(root, "docs", "CURRENT_STATE.md"), "utf8");
for (const requiredFact of [canonicalPool, positionNft, positionFinalization, "integrationReady: false"]) {
  if (!currentState.includes(requiredFact)) {
    errors.push(`docs/CURRENT_STATE.md: missing current-state fact ${requiredFact}`);
  }
}

const synchronization = await readFile(
  join(root, "docs", "NARA-20260830-public-v4-state-sync.md"),
  "utf8",
);
for (const requiredFact of [
  protocolDocsCommit,
  basketsDocsCommit,
  monitorDocsCommit,
]) {
  if (!synchronization.includes(requiredFact)) {
    errors.push(`documentation synchronization: missing protected main commit ${requiredFact}`);
  }
}

const legal = await readFile(join(root, "LEGAL.md"), "utf8");
for (const requiredFact of [
  "2026-08-31",
  "Independent qualified legal review | **Not completed**",
  "https://eur-lex.europa.eu/eli/reg/2023/1114",
  "https://www.fca.org.uk/publications/fg23-3-finalised-non-handbook-guidance-cryptoasset-financial-promotions",
]) {
  if (!legal.includes(requiredFact)) {
    errors.push(`LEGAL.md: missing legal-review fact ${requiredFact}`);
  }
}

const workflow = await readFile(
  join(root, ".github", "workflows", "docs.yml"),
  "utf8",
);
function workflowActionReferences(content) {
  const reference = /^\s*uses:\s*(actions\/(?:checkout|setup-node))@([^\s#]+).*$/gm;
  return [...content.matchAll(reference)].map((match) => ({
    action: match[1],
    ref: match[2],
  }));
}

function unpinnedWorkflowReferences(content) {
  return workflowActionReferences(content)
    .filter((reference) => !/^[a-f0-9]{40}$/.test(reference.ref));
}

const workflowReferences = workflowActionReferences(workflow);
for (const action of ["actions/checkout", "actions/setup-node"]) {
  if (!workflowReferences.some((reference) => reference.action === action)) {
    errors.push(`.github/workflows/docs.yml: missing required action ${action}`);
  }
}
for (const reference of unpinnedWorkflowReferences(workflow)) {
  errors.push(
    `.github/workflows/docs.yml: ${reference.action}@${reference.ref} must use an immutable full SHA`,
  );
}

const floatingTagFixture = workflow.replace(
  /actions\/checkout@[a-f0-9]{40}/,
  "actions/checkout@v4",
);
const floatingTagDetected = unpinnedWorkflowReferences(floatingTagFixture)
  .some((reference) => reference.action === "actions/checkout" && reference.ref === "v4");
if (!floatingTagDetected) {
  errors.push("workflow action pinning negative regression fixture failed");
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
