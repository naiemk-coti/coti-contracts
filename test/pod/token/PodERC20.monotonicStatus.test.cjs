/**
 * Monotonic settlement: Success / Failed / SystemFailed only from Pending.
 * Run: `node --test test/pod/token/PodERC20.monotonicStatus.test.cjs`
 */
const assert = require("node:assert/strict");
const { describe, it } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

describe("PodERC20 monotonic request status", () => {
  it("gates terminal statuses on Pending in _setRequestStatus", () => {
    const src = fs.readFileSync(
      path.join(__dirname, "../../../contracts/pod/token/perc20/PodERC20.sol"),
      "utf8"
    );
    const start = src.indexOf("function _setRequestStatus");
    assert.ok(start > -1);
    const body = src.slice(start, start + 800);
    assert.ok(body.includes("RequestNotPending"));
    assert.ok(body.includes("RequestStatus.Pending"));
    assert.ok(body.includes("RequestStatus.Success"));
    assert.ok(body.includes("RequestStatus.SystemFailed"));
  });
});
