import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, normalize, resolve, sep } from "node:path";
import process from "node:process";

const EXPECTED_COMMIT = "3215b69a1154b9c30957cd8d875b636dedc9d0ca";
const root = resolve(import.meta.dirname, "..");
const sourceRoot = resolve(process.argv[2] ?? "");
const outputRoot = join(root, "verification");
const sourceOutput = join(outputRoot, "sources");
const artifactOutput = join(outputRoot, "artifacts");

if (!process.argv[2] || !isAbsolute(process.argv[2])) {
  throw new Error("Usage: node scripts/export-verification.mjs <absolute-release-worktree>");
}
if (sourceRoot === root || outputRoot === root || !outputRoot.startsWith(`${root}${sep}`)) {
  throw new Error("Unsafe verification export path");
}

const releaseCommit = execFileSync(
  "git",
  ["rev-parse", "HEAD"],
  { cwd: sourceRoot, encoding: "utf8" },
).trim();
if (releaseCommit !== EXPECTED_COMMIT) {
  throw new Error(`Expected release ${EXPECTED_COMMIT}, received ${releaseCommit}`);
}

const entrypoints = [
  ["contracts/v4/NARALauncher.sol", "NARALauncher"],
  ["contracts/v4/NARAToken.sol", "NARAToken"],
  ["contracts/v4/NARAEngine.sol", "NARAEngine"],
  ["contracts/v4/NARARewardReserve.sol", "NARARewardReserve"],
  ["contracts/v4/NARALiquidityGrowthVault.sol", "NARALiquidityGrowthVault"],
  ["contracts/v4/utils/Create2HookDeployer.sol", "Create2HookDeployer"],
  ["contracts/v4/NARALiquidityGrowthHook.sol", "NARALiquidityGrowthHook"],
  ["contracts/v4/NARALiquidityCompounderV4.sol", "NARALiquidityCompounderV4"],
];

function slash(path) {
  return path.split(sep).join("/");
}

function hash(content) {
  return createHash("sha256").update(content).digest("hex");
}

function localImport(from, imported) {
  if (imported.startsWith("@")) return null;
  const candidate = imported.startsWith("contracts/")
    ? imported
    : slash(normalize(join(dirname(from), imported)));
  if (!candidate.startsWith("contracts/v4/")) {
    throw new Error(`Active source imports outside v4: ${from} -> ${imported}`);
  }
  return candidate;
}

async function collectSources(path, collected) {
  if (collected.has(path)) return;
  const content = await readFile(join(sourceRoot, path), "utf8");
  collected.set(path, content);
  const imports = content.matchAll(/import\s+(?:[^"']+from\s+)?["']([^"']+)["'];/g);
  for (const match of imports) {
    const dependency = localImport(path, match[1]);
    if (dependency) await collectSources(dependency, collected);
  }
}

await rm(sourceOutput, { recursive: true, force: true });
await rm(artifactOutput, { recursive: true, force: true });
await rm(join(outputRoot, "release.json"), { force: true });
await mkdir(outputRoot, { recursive: true });
await mkdir(sourceOutput, { recursive: true });
await mkdir(artifactOutput, { recursive: true });

const sources = new Map();
for (const [source] of entrypoints) await collectSources(source, sources);

const sourceInventory = [];
for (const [path, content] of [...sources].sort(([a], [b]) => a.localeCompare(b))) {
  const destination = join(sourceOutput, path);
  await mkdir(dirname(destination), { recursive: true });
  await writeFile(destination, content, "utf8");
  sourceInventory.push({ path, sha256: hash(content.replaceAll("\r\n", "\n")) });
}

const artifacts = [];
const buildInfoDirectory = join(sourceRoot, "artifacts", "build-info");
const buildInfoFiles = (await readdir(buildInfoDirectory))
  .filter((name) => name.endsWith(".json") && !name.endsWith(".output.json"));
const buildInfos = await Promise.all(
  buildInfoFiles.map(async (name) =>
    JSON.parse(await readFile(join(buildInfoDirectory, name), "utf8"))
  ),
);
for (const [source, contract] of entrypoints) {
  const artifactPath = join(sourceRoot, "artifacts", source, `${contract}.json`);
  const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
  const buildInfo = buildInfos.find((candidate) =>
    Object.hasOwn(candidate.input.sources, `project/${source}`)
  );
  if (!buildInfo) throw new Error(`No build info found for ${source}`);

  const sanitized = {
    format: artifact._format,
    contractName: artifact.contractName,
    sourceName: artifact.sourceName,
    abi: artifact.abi,
    bytecode: artifact.bytecode,
    deployedBytecode: artifact.deployedBytecode,
    linkReferences: artifact.linkReferences,
    deployedLinkReferences: artifact.deployedLinkReferences,
  };
  await writeFile(
    join(artifactOutput, `${contract}.json`),
    `${JSON.stringify(sanitized, null, 2)}\n`,
    "utf8",
  );
  artifacts.push({
    contract,
    source,
    artifact: `verification/artifacts/${contract}.json`,
    sha256: hash(JSON.stringify(sanitized)),
    compiler: {
      buildId: buildInfo.id,
      solcLongVersion: buildInfo.solcLongVersion,
      solcVersion: buildInfo.solcVersion,
      settings: buildInfo.input.settings,
    },
  });
}

const lock = JSON.parse(await readFile(join(sourceRoot, "package-lock.json"), "utf8"));
const packageVersion = (name) => lock.packages?.[`node_modules/${name}`]?.version ?? null;
const release = {
  schemaVersion: 1,
  sourceCommit: releaseCommit,
  sourceDate: "2026-07-26",
  network: "base",
  chainId: 8453,
  dependencies: {
    "@openzeppelin/contracts": packageVersion("@openzeppelin/contracts"),
    "@uniswap/v4-core": packageVersion("@uniswap/v4-core"),
    "@uniswap/v4-periphery": packageVersion("@uniswap/v4-periphery"),
  },
  entrypoints: artifacts,
  sources: sourceInventory,
};
await writeFile(
  join(outputRoot, "release.json"),
  `${JSON.stringify(release, null, 2)}\n`,
  "utf8",
);

console.log(
  `Exported ${sources.size} dependency-complete source files and ${artifacts.length} artifacts from ${releaseCommit}.`,
);
