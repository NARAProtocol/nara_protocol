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
  "docs/NARA_Canonical.md",
  "docs/CURRENT_STATE.md",
  "docs/TOKEN_AND_ALLOCATION.md",
  "docs/LIQUIDITY.md",
  "docs/REWARDS.md",
  "docs/Technical_Architecture.md",
  "docs/ADMIN_POWERS.md",
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
  ["retired historical token 0xB633", /0xB6333F5D4cEd8dffA80F3F13697D6aA3BB3f19c1/gi],
  ["retired historical token 0x58c2", /0x58c209B95350aFBEFa17137CEd209f8c4b7D896D/gi],
  ["hallucinated NARACompoundRouterV5", /\bNARACompoundRouterV5\b|0x53864427646BD184FBe61fd6b329DC2091172427/gi],
  ["hallucinated NARAEntropyGateV5", /\bNARAEntropyGateV5\b|0x90fA885579B2D9bBb8cd7fA95eD336eD59C48332/gi],
  ["hallucinated NARAPositionDescriptorV5", /\bNARAPositionDescriptorV5\b|0x252b0296747e9C0EB045F3EA74E6efFBc136A214/gi],
  ["hallucinated NARAPositionAccountV5", /\bNARAPositionAccountV5\b|0x329346969Cbf55365F29182Be35dE6B472B366dF/gi],
  ["wrong VRF Safe address", /0x9d41EBFF8b6A902C07ddbf2846BeffefE3FF766d/gi],
  ["wrong Presentation Safe address", /0x09395d87e229909a7B0314bC89b79B9035D5e466/gi],
  ["retired v3 engine name", /\bNARAEngineV2\b/g],
  ["obsolete mining route", /\/mine\b/g],
  ["guaranteed-return wording", /\bguaranteed (?:yield|return|profit)\b/gi],
  ["forbidden earn wording", /\bearn(?:s|ed|ing|ings)?\b/gi],
  ["forbidden referral link", /Referral|startapp=slip_/gi],
  ["forbidden lock wording", /\b(?!block(?:s|chain|chains|scout)?\b)[a-zA-Z]*lock[a-zA-Z]*\b/gi],
  ["private engineering repository link", /github\.com\/NARAProtocol\/nara_protocol_v4/gi],
  ["Lithuanian diacritics", /[\u0105\u010d\u0119\u0117\u012f\u0161\u0173\u016b\u017e]/gi],
  ["Lithuanian word leak", /\b(?:Variantas|Perliukai)\b/gi],
  ["deprecated naraprotocol.com/.pro domain", /naraprotocol\.(?:com|pro)\b/gi],
  ["placeholder", /\b(?:TODO|TBD|FIXME)\b/g],
  ["ellipsis placeholder", /^\s*(?:\.\.\.|\u2026)\s*$/gm],
];
const markdownLink = /!?\[[^\]]*\]\(([^)]+)\)/g;
const errors = [];

const canonicalToken = "0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f";
const v5CoreAddresses = [
  canonicalToken,
  "0xf932178F24b0813C82093985F0Af6Db27Ae25930", // NARAEmissionReserveV5
  "0xd93FbEbFb33FAc9288125074625D4750573B1a53", // NARAEpochEngineV5
  "0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2", // NARAPrincipalLedgerV5
  "0xC72671D9438388638547444524F6542b650C9264", // NARARewardLedgerV5
  "0x8C5F088D9d09dBB90aB6F3aaA049a8FD5D5FfFDA", // NARAPositionNFTV5
  "0x04Ac83045d26259D46400Ce6beb9bBd0641df225", // NARAPositionSaleV5 (5% / 500 bps)
  "0x44130CC47b886D8488041F5eaE271477D1aFA909", // NARARewardIngressV5
  "0x201fBD2839bEc513040024b37dAe97B401E96acC", // NARALiquidityHookV5
  "0xe63b4BaAF873FC57859bfe13e0e8cFccAaB6AddE", // NARAFeeVaultV5
  "0x01EF9de9f4e9197F2A3944b5B34A90eA2f558b64", // NARAPOLPositionV5
  "0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288", // NARATreasuryRangeManagerV5
  "0xe320C281c86079eA85f2Bc67864E873A61D551E3", // Treasury Safe
  "0x9d415e070AF8e93890dcCaE27755C66E3A313f0F", // OA-3 VRF Governance Safe
  "0x0939BE9a5359764C2334a70A13eC567C7e38E017", // C1 Presentation Governor Safe
];

async function walk(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if ([".git", ".worktrees", "node_modules"].includes(entry.name)) continue;
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

for (const path of ["README.md", "docs/User_Guide.md", "docs/CURRENT_STATE.md", "docs/TOKEN_AND_ALLOCATION.md"]) {
  const content = await readFile(join(root, path), "utf8");
  if (!content.includes(canonicalToken)) {
    errors.push(`${path}: missing canonical NARA token address ${canonicalToken}`);
  }
}

const readme = await readFile(join(root, "README.md"), "utf8");
const currentState = await readFile(join(root, "docs", "CURRENT_STATE.md"), "utf8");
for (const address of v5CoreAddresses) {
  if (!readme.includes(address)) {
    errors.push(`README.md: missing V5 contract address ${address}`);
  }
  if (!currentState.includes(address)) {
    errors.push(`docs/CURRENT_STATE.md: missing V5 contract address ${address}`);
  }
}

const tokenDocumentation = await readFile(
  join(root, "docs", "TOKEN_AND_ALLOCATION.md"),
  "utf8",
);
for (const requiredFact of ["1,000,000", "949,987", "49,997", "100,000 NARA", "0.10%", "ERC-3156"]) {
  if (!tokenDocumentation.includes(requiredFact)) {
    errors.push(`docs/TOKEN_AND_ALLOCATION.md: missing required V5 token/allocation fact ${requiredFact}`);
  }
}

const legal = await readFile(join(root, "LEGAL.md"), "utf8");
for (const requiredFact of [
  "https://eur-lex.europa.eu/eli/reg/2023/1114",
  "https://www.fca.org.uk/publications/fg23-3-finalised-non-handbook-guidance-cryptoasset-financial-promotions",
]) {
  if (!legal.includes(requiredFact)) {
    errors.push(`LEGAL.md: missing legal-review reference ${requiredFact}`);
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

if (files.some((file) => relative(root, file).startsWith(`contracts${process.platform === "win32" ? "\\" : "/"}`))) {
  errors.push("contracts/: historical contract source must not return to the public docs repository");
}

if (errors.length > 0) {
  console.error("Documentation verification failed:");
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

console.log(`Documentation verification passed (${textFiles.length} files checked).`);
