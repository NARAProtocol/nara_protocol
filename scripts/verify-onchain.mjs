import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import process from "node:process";

const root = resolve(import.meta.dirname, "..");
const deployment = JSON.parse(
  await readFile(resolve(root, "verification", "deployment.json"), "utf8"),
);
const rpcUrl = process.env.BASE_RPC_URL;
if (!rpcUrl) {
  throw new Error("Set BASE_RPC_URL to a Base mainnet JSON-RPC endpoint");
}

let requestId = 0;
async function rpc(method, params) {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: ++requestId,
      method,
      params,
    }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok) throw new Error(`RPC HTTP ${response.status}`);
  const body = await response.json();
  if (body.error) throw new Error(`RPC ${body.error.code}: ${body.error.message}`);
  return body.result;
}

const chainId = Number.parseInt(await rpc("eth_chainId", []), 16);
if (chainId !== deployment.chainId) {
  throw new Error(`Wrong network: expected chain ${deployment.chainId}, received ${chainId}`);
}

const checkpoint = `0x${deployment.verificationBlock.toString(16)}`;
const failures = [];
for (const [name, contract] of Object.entries(deployment.contracts)) {
  const code = await rpc("eth_getCode", [contract.address, checkpoint]);
  if (code === "0x") {
    failures.push(`${name}: no code at checkpoint`);
    continue;
  }
  const digest = createHash("sha256")
    .update(Buffer.from(code.slice(2), "hex"))
    .digest("hex");
  if (digest !== contract.runtimeCodeSha256) {
    failures.push(`${name}: runtime code mismatch`);
  }
}

if (failures.length > 0) {
  console.error("Onchain verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log(
  `Onchain verification passed for ${Object.keys(deployment.contracts).length} contracts at Base block ${deployment.verificationBlock}.`,
);
