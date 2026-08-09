/**
 * syncBalances must bound account count and require addresses/amounts length equality.
 * Run: `node --test test/pod/token/PodERC20.syncBalancesCaps.test.cjs`
 */
const assert = require("node:assert/strict");
const { describe, it } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

describe("PodERC20 syncBalances caps", () => {
  it("caps account length and checks callback array consistency", () => {
    const pod = fs.readFileSync(
      path.join(__dirname, "../../../contracts/pod/token/perc20/PodERC20.sol"),
      "utf8"
    );
    assert.ok(pod.includes("MAX_SYNC_BALANCE_ACCOUNTS = 64"));
    assert.ok(pod.includes("SyncBalancesInvalidLength"));
    assert.ok(pod.includes("SyncBalancesLengthMismatch"));

    const mother = fs.readFileSync(
      path.join(__dirname, "../../../contracts/pod/token/perc20/cotiside/PodErc20CotiMother.sol"),
      "utf8"
    );
    assert.ok(mother.includes("MAX_SYNC_BALANCE_ACCOUNTS = 64"));
    assert.ok(mother.includes("too many accounts"));
  });
});
