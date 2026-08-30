import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import process from "node:process";

const root = resolve(import.meta.dirname, "..");
const deployment = JSON.parse(
  await readFile(resolve(root, "verification", "deployment.json"), "utf8"),
);
const positionDeployment = {
  verificationBlock: 50296367,
  finalizationTransaction:
    "0xfb83cb4cb4b8a2c30216f46be69b519628ad74259795806e30d158a7736c6e8f",
  contracts: {
    positionRenderer: "0x607b08365C23a983C542898a79E670e6D4B80673",
    positionAccount: "0x3a8c9cA4f95E94751774810B33caF01bb992A55F",
    positionNft: "0xCcBD8c59664958636369F8fe24B927aEBc3DF7cC",
  },
};
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

const positionCheckpoint = `0x${positionDeployment.verificationBlock.toString(16)}`;
for (const [name, address] of Object.entries(positionDeployment.contracts)) {
  const code = await rpc("eth_getCode", [address, positionCheckpoint]);
  if (code === "0x") failures.push(`${name}: no code at Position NFT checkpoint`);
}

const finalizationReceipt = await rpc("eth_getTransactionReceipt", [
  positionDeployment.finalizationTransaction,
]);
if (
  !finalizationReceipt ||
  finalizationReceipt.status !== "0x1" ||
  Number.parseInt(finalizationReceipt.blockNumber, 16) !== positionDeployment.verificationBlock
) {
  failures.push("Position NFT: Safe finalization receipt mismatch");
}

if (failures.length > 0) {
  console.error("Onchain verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log(
  `Onchain verification passed for ${Object.keys(deployment.contracts).length} core contracts at Base block ${deployment.verificationBlock}, plus ${Object.keys(positionDeployment.contracts).length} Position NFT contracts and Safe finalization at block ${positionDeployment.verificationBlock}.`,
);
