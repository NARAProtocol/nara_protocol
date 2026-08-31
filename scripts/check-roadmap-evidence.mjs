import { createHash } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";
import process from "node:process";

const root = resolve(import.meta.dirname, "..");
const ledgerPath = resolve(root, "docs", "ROADMAP_EVIDENCE.json");
const allowedRoadmapStatuses = new Set([
  "completed",
  "next_gate",
  "future_gate",
  "deferred",
  "retired",
]);
const allowedWorkStates = new Set(["not_started", "partial", "complete", "retired"]);
const evidenceRank = new Map([
  ["implemented", 0],
  ["tested", 1],
  ["merged", 2],
  ["deployed", 3],
  ["configured", 4],
  ["indexed", 5],
  ["activated", 6],
  ["available", 7],
]);
const allowedAvailability = new Set([
  "unavailable",
  "preview",
  "technical_live_testing",
  "available",
]);
const expectedRemotes = new Map([
  ["protocol", "NARAProtocol/nara_protocol_v4"],
  ["baskets", "NARAProtocol/nara_protocol_v4_baskets"],
  ["monitor", "NARAProtocol/nara-swarm-monitor"],
]);
const normalizeNewlines = (content) => content.replaceAll("\r\n", "\n");
const hash = (content) => createHash("sha256")
  .update(normalizeNewlines(content))
  .digest("hex");
const normalizeClaim = (content) => normalizeNewlines(content)
  .replace(/\s+/g, " ")
  .trim()
  .toLowerCase();

function validateEvidenceEntry(evidence) {
  const errors = [];
  if (evidence === null || typeof evidence !== "object" || Array.isArray(evidence)) {
    return ["evidence reference must be an object"];
  }
  if (!new Set(["protocol", "baskets", "monitor"]).has(evidence.repository)) {
    errors.push(`invalid upstream repository ${evidence.repository}`);
  }
  if (
    typeof evidence.path !== "string" ||
    evidence.path.length === 0 ||
    evidence.path.startsWith("/") ||
    evidence.path.includes("\\") ||
    evidence.path.split("/").includes("..")
  ) {
    errors.push("upstream evidence path must be repository-relative");
  }
  if (evidence.assertions !== undefined) {
    if (!Array.isArray(evidence.assertions) || evidence.assertions.length === 0) {
      errors.push("assertions must be a non-empty array");
    } else {
      for (const assertion of evidence.assertions) {
        if (typeof assertion.jsonPath !== "string" || assertion.jsonPath.length === 0) {
          errors.push("assertion jsonPath is required");
        }
        if (!Object.hasOwn(assertion, "equals")) {
          errors.push("assertion equals value is required");
        }
      }
    }
  }
  return errors;
}

function validateItem(item) {
  const errors = [];
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(item.id ?? "")) {
    errors.push("id must be stable lowercase kebab-case");
  }
  if (!allowedRoadmapStatuses.has(item.roadmapStatus)) {
    errors.push(`unsupported roadmapStatus ${item.roadmapStatus}`);
  }
  if (!allowedWorkStates.has(item.workState)) {
    errors.push(`unsupported workState ${item.workState}`);
  }
  if (item.evidenceState !== null && !evidenceRank.has(item.evidenceState)) {
    errors.push(`unsupported evidenceState ${item.evidenceState}`);
  }
  if (!allowedAvailability.has(item.availability)) {
    errors.push(`unsupported availability ${item.availability}`);
  }
  if (item.roadmapStatus === "completed" && item.workState !== "complete") {
    errors.push("completed roadmap status requires complete actual work");
  }
  if (item.workState === "complete" && item.roadmapStatus !== "completed") {
    errors.push("complete actual work must be moved to the completed roadmap section");
  }
  if (
    item.workState === "complete" &&
    (evidenceRank.get(item.evidenceState) ?? -1) < evidenceRank.get("tested")
  ) {
    errors.push("complete actual work requires at least tested evidence");
  }
  if (
    item.workState === "partial" &&
    item.evidenceState === null
  ) {
    errors.push("partial actual work requires positive evidence");
  }
  if (item.workState === "not_started" && item.evidenceState !== null) {
    errors.push("not-started work must not claim an evidence state");
  }
  if (
    item.availability === "technical_live_testing" &&
    (evidenceRank.get(item.evidenceState) ?? -1) < evidenceRank.get("activated")
  ) {
    errors.push("technical live testing requires activated evidence");
  }
  if (item.availability === "technical_live_testing" && item.workState !== "complete") {
    errors.push("technical live testing requires complete actual work");
  }
  if (item.availability === "preview") {
    if (item.workState !== "partial") {
      errors.push("preview requires partial actual work");
    }
    if ((evidenceRank.get(item.evidenceState) ?? -1) < evidenceRank.get("implemented")) {
      errors.push("preview requires at least implemented evidence");
    }
  }
  if (item.availability === "available") {
    if (item.evidenceState !== "available") {
      errors.push("available requires evidenceState available");
    }
    if (!Array.isArray(item.userFlowEvidence) || item.userFlowEvidence.length === 0) {
      errors.push("available requires user-flow evidence");
    }
    if (!Array.isArray(item.exitPathEvidence) || item.exitPathEvidence.length === 0) {
      errors.push("available requires exit-path evidence");
    }
  }
  if (
    item.evidenceState !== null &&
    (!Array.isArray(item.upstreamEvidence) || item.upstreamEvidence.length === 0)
  ) {
    errors.push("positive evidence state requires immutable upstream evidence");
  }
  for (const field of ["roadmapSection", "roadmapClaim", "currentStateClaim"]) {
    if (typeof item[field] !== "string" || item[field].trim().length === 0) {
      errors.push(`${field} is required`);
    }
  }
  if (!Array.isArray(item.localEvidence) || item.localEvidence.length === 0) {
    errors.push("localEvidence is required");
  }
  for (const field of ["upstreamEvidence", "userFlowEvidence", "exitPathEvidence"]) {
    if (!Array.isArray(item[field])) errors.push(`${field} must be an array`);
  }
  for (const evidence of allUpstreamEvidence(item)) {
    errors.push(...validateEvidenceEntry(evidence));
  }
  return errors;
}

function runNegativeRegressionFixtures() {
  const base = {
    id: "fixture",
    roadmapSection: "Fixture",
    roadmapClaim: "Fixture roadmap claim",
    currentStateClaim: "Fixture state claim",
    roadmapStatus: "completed",
    workState: "complete",
    evidenceState: "tested",
    availability: "unavailable",
    localEvidence: ["docs/ROADMAP.md"],
    upstreamEvidence: [{ repository: "protocol", path: "fixture" }],
    userFlowEvidence: [],
    exitPathEvidence: [],
  };

  const weakCompletion = validateItem({ ...base, evidenceState: "implemented" });
  if (!weakCompletion.some((error) => error.includes("at least tested"))) {
    throw new Error("Negative fixture failed: weak completed evidence was accepted");
  }

  const unavailableExit = validateItem({
    ...base,
    roadmapStatus: "next_gate",
    workState: "partial",
    evidenceState: "available",
    availability: "available",
  });
  if (
    !unavailableExit.some((error) => error.includes("user-flow")) ||
    !unavailableExit.some((error) => error.includes("exit-path"))
  ) {
    throw new Error("Negative fixture failed: availability without flow/exit evidence was accepted");
  }

  const roadmapAhead = validateItem({ ...base, workState: "partial" });
  if (!roadmapAhead.some((error) => error.includes("requires complete actual work"))) {
    throw new Error("Negative fixture failed: roadmap ahead of actual work was accepted");
  }

  const workAhead = validateItem({
    ...base,
    roadmapStatus: "next_gate",
    workState: "complete",
  });
  if (!workAhead.some((error) => error.includes("must be moved to the completed"))) {
    throw new Error("Negative fixture failed: actual work ahead of roadmap was accepted");
  }

  const emptyPreview = validateItem({
    ...base,
    roadmapStatus: "future_gate",
    workState: "not_started",
    evidenceState: null,
    availability: "preview",
    upstreamEvidence: [],
  });
  if (!emptyPreview.some((error) => error.includes("preview requires"))) {
    throw new Error("Negative fixture failed: unevidenced preview was accepted");
  }

  const fakeAvailabilityEvidence = validateItem({
    ...base,
    evidenceState: "available",
    availability: "available",
    userFlowEvidence: ["does-not-exist"],
    exitPathEvidence: ["does-not-exist"],
  });
  if (!fakeAvailabilityEvidence.some((error) => error.includes("must be an object"))) {
    throw new Error("Negative fixture failed: unresolved availability evidence was accepted");
  }
}

function extractRoadmapBullets(content) {
  const bullets = [];
  let section;
  let pending;

  const flush = () => {
    if (pending) bullets.push({ section, claim: pending });
    pending = undefined;
  };

  for (const line of normalizeNewlines(content).split("\n")) {
    const heading = line.match(/^##\s+(.+?)\s*$/);
    if (heading) {
      flush();
      section = heading[1];
      continue;
    }
    if (!section) continue;

    const bullet = line.match(/^-\s+(.+?)\s*$/);
    if (bullet) {
      flush();
      pending = bullet[1];
      continue;
    }
    const continuation = line.match(/^\s{2,}(\S.*?)\s*$/);
    if (pending && continuation) {
      pending += ` ${continuation[1]}`;
      continue;
    }
    if (line.trim() !== "") flush();
  }
  flush();
  return bullets;
}

function allUpstreamEvidence(item) {
  return [
    ...(item.upstreamEvidence ?? []),
    ...(item.userFlowEvidence ?? []),
    ...(item.exitPathEvidence ?? []),
  ];
}

function resolveLocalEvidence(path) {
  if (typeof path !== "string" || path.length === 0 || isAbsolute(path)) {
    throw new Error(`Invalid local evidence path: ${path}`);
  }
  const absolute = resolve(root, path);
  const display = relative(root, absolute);
  if (display.startsWith("..") || isAbsolute(display)) {
    throw new Error(`Local evidence escapes repository root: ${path}`);
  }
  return absolute;
}

function getJsonPathValue(object, jsonPath) {
  let value = object;
  for (const segment of jsonPath.split(".")) {
    if (value === null || typeof value !== "object" || !(segment in value)) {
      throw new Error(`missing JSON path ${jsonPath} at ${segment}`);
    }
    value = value[segment];
  }
  return value;
}

async function fetchUpstream(url) {
  const headers = {
    Accept: "application/vnd.github+json",
    "User-Agent": "nara-public-roadmap-evidence-gate",
  };
  if (process.env.GITHUB_TOKEN && url.startsWith("https://api.github.com/")) {
    headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  }
  const response = await fetch(url, {
    headers,
    redirect: "follow",
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`upstream request failed (${response.status}): ${url}`);
  return response;
}

async function verifyUpstreamEvidence(ledger) {
  let checks = 0;
  for (const repository of ["protocol", "baskets", "monitor"]) {
    const source = ledger.repositories[repository];
    const response = await fetchUpstream(
      `https://api.github.com/repos/${source.remote}/commits/main`,
    );
    const latest = await response.json();
    if (latest.sha !== source.protectedMainReviewed) {
      throw new Error(
        `${repository} protected main drift: expected ${source.protectedMainReviewed}, received ${latest.sha}`,
      );
    }
    checks++;
  }

  for (const document of ledger.repositories.protocol.authoritativeDocuments) {
    const source = ledger.repositories.protocol;
    const encodedPath = document.path.split("/").map(encodeURIComponent).join("/");
    const url = `https://raw.githubusercontent.com/${source.remote}/${source.protectedMainReviewed}/${encodedPath}`;
    const bytes = Buffer.from(await (await fetchUpstream(url)).arrayBuffer());
    const actualHash = createHash("sha256").update(bytes).digest("hex");
    if (actualHash !== document.sha256) {
      throw new Error(
        `authoritative protocol document drift at ${document.path}: expected ${document.sha256}, received ${actualHash}`,
      );
    }
    checks++;
  }

  const contentCache = new Map();
  for (const item of ledger.items) {
    for (const evidence of allUpstreamEvidence(item)) {
      const source = ledger.repositories[evidence.repository];
      const encodedPath = evidence.path.split("/").map(encodeURIComponent).join("/");
      const url = `https://raw.githubusercontent.com/${source.remote}/${source.protectedMainReviewed}/${encodedPath}`;
      let content = contentCache.get(url);
      if (content === undefined) {
        content = await (await fetchUpstream(url)).text();
        contentCache.set(url, content);
      }
      checks++;

      if (evidence.assertions) {
        const json = JSON.parse(content);
        for (const assertion of evidence.assertions) {
          const actual = getJsonPathValue(json, assertion.jsonPath);
          if (JSON.stringify(actual) !== JSON.stringify(assertion.equals)) {
            throw new Error(
              `${item.id} assertion failed at ${evidence.path}:${assertion.jsonPath}`,
            );
          }
          checks++;
        }
      }
    }
  }
  return checks;
}

runNegativeRegressionFixtures();

const ledger = JSON.parse(await readFile(ledgerPath, "utf8"));
if (ledger.documents?.roadmapPath !== "docs/ROADMAP.md") {
  throw new Error("documents.roadmapPath must be docs/ROADMAP.md");
}
if (ledger.documents?.currentStatePath !== "docs/CURRENT_STATE.md") {
  throw new Error("documents.currentStatePath must be docs/CURRENT_STATE.md");
}
const roadmapPath = resolveLocalEvidence(ledger.documents?.roadmapPath);
const currentStatePath = resolveLocalEvidence(ledger.documents?.currentStatePath);
const roadmap = await readFile(roadmapPath, "utf8");
const currentState = await readFile(currentStatePath, "utf8");

if (process.argv.includes("--print-hashes")) {
  console.log(JSON.stringify({
    roadmapSha256: hash(roadmap),
    currentStateSha256: hash(currentState),
  }, null, 2));
  process.exit(0);
}

const errors = [];
if (ledger.schemaVersion !== 1) errors.push("schemaVersion must be 1");
if (!/^NARA-\d{8}-[a-z0-9-]+$/.test(ledger.changeId ?? "")) {
  errors.push("changeId must use NARA-YYYYMMDD-slug");
}
for (const repository of ["protocol", "baskets", "monitor"]) {
  const source = ledger.repositories?.[repository];
  if (!source || !/^[a-f0-9]{40}$/.test(source.protectedMainReviewed ?? "")) {
    errors.push(`${repository}.protectedMainReviewed must be a full commit`);
  }
  if (source?.remote !== expectedRemotes.get(repository)) {
    errors.push(`${repository}.remote must match the canonical repository`);
  }
}
const authoritativeDocuments = ledger.repositories?.protocol?.authoritativeDocuments;
const expectedAuthoritativeDocuments = new Set(["docs/ROADMAP.md", "docs/CURRENT_STATE.md"]);
if (!Array.isArray(authoritativeDocuments) || authoritativeDocuments.length !== 2) {
  errors.push("protocol.authoritativeDocuments must pin roadmap and current state");
} else {
  for (const document of authoritativeDocuments) {
    if (!expectedAuthoritativeDocuments.delete(document.path)) {
      errors.push(`unexpected authoritative protocol document: ${document.path}`);
    }
    if (!/^[a-f0-9]{64}$/.test(document.sha256 ?? "")) {
      errors.push(`invalid authoritative protocol document hash: ${document.path}`);
    }
  }
  if (expectedAuthoritativeDocuments.size > 0) {
    errors.push("protocol.authoritativeDocuments is missing a required document");
  }
}
if (hash(roadmap) !== ledger.documents?.roadmapSha256) {
  errors.push(`roadmap hash mismatch; current ${hash(roadmap)}`);
}
if (hash(currentState) !== ledger.documents?.currentStateSha256) {
  errors.push(`current-state hash mismatch; current ${hash(currentState)}`);
}

const currentStateNormalized = normalizeClaim(currentState);
const roadmapBullets = extractRoadmapBullets(roadmap);
const roadmapBulletByClaim = new Map(
  roadmapBullets.map((bullet) => [normalizeClaim(bullet.claim), bullet]),
);
const roadmapClaimCounts = new Map();
const seenIds = new Set();
for (const item of ledger.items ?? []) {
  const itemErrors = validateItem(item);
  for (const error of itemErrors) errors.push(`${item.id ?? "unknown"}: ${error}`);
  if (seenIds.has(item.id)) errors.push(`${item.id}: duplicate roadmap item id`);
  seenIds.add(item.id);
  const normalizedRoadmapClaim = normalizeClaim(item.roadmapClaim ?? "");
  const roadmapBullet = roadmapBulletByClaim.get(normalizedRoadmapClaim);
  roadmapClaimCounts.set(
    normalizedRoadmapClaim,
    (roadmapClaimCounts.get(normalizedRoadmapClaim) ?? 0) + 1,
  );
  if (!roadmapBullet) {
    errors.push(`${item.id}: roadmap claim is not an exact tracked roadmap bullet`);
  } else if (roadmapBullet.section !== item.roadmapSection) {
    errors.push(`${item.id}: roadmapSection does not match the bullet heading`);
  }
  if (!currentStateNormalized.includes(normalizeClaim(item.currentStateClaim ?? ""))) {
    errors.push(`${item.id}: actual-state claim is absent from docs/CURRENT_STATE.md`);
  }

  for (const path of item.localEvidence ?? []) {
    try {
      if (!(await stat(resolveLocalEvidence(path))).isFile()) {
        errors.push(`${item.id}: local evidence is not a file: ${path}`);
      }
    } catch {
      errors.push(`${item.id}: missing local evidence: ${path}`);
    }
  }
}
for (const bullet of roadmapBullets) {
  const count = roadmapClaimCounts.get(normalizeClaim(bullet.claim)) ?? 0;
  if (count !== 1) {
    errors.push(`roadmap bullet must have exactly one evidence item (${count} found): ${bullet.claim}`);
  }
}
if ((ledger.items ?? []).length !== roadmapBullets.length) {
  errors.push(
    `roadmap item count mismatch: ${ledger.items?.length ?? 0} ledger items for ${roadmapBullets.length} bullets`,
  );
}

let upstreamChecks = 0;
if (errors.length === 0 && process.argv.includes("--verify-upstream")) {
  try {
    upstreamChecks = await verifyUpstreamEvidence(ledger);
  } catch (error) {
    errors.push(`upstream verification failed: ${error.message}`);
  }
}

if (errors.length > 0) {
  console.error("Roadmap evidence verification failed:");
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

console.log(
  `Roadmap evidence verification passed (${ledger.items.length} items; roadmap and current-state hashes match${upstreamChecks > 0 ? `; ${upstreamChecks} upstream checks` : ""}).`,
);
