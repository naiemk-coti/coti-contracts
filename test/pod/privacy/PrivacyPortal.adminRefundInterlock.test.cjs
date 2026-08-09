/**
 * Portal admin refund must invalidate a Pending mint before releasing collateral.
 * Run: `node --test test/pod/privacy/PrivacyPortal.adminRefundInterlock.test.cjs`
 */
const assert = require("node:assert/strict");
const { describe, it } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

describe("PrivacyPortal admin refund interlock", () => {
  it("calls invalidatePendingRequest before releasing escrow on Pending mints", () => {
    const portal = fs.readFileSync(
      path.join(__dirname, "../../../contracts/pod/privacy/PrivacyPortal.sol"),
      "utf8"
    );
    const start = portal.indexOf("function adminRefundPendingDeposit");
    assert.ok(start > -1);
    const body = portal.slice(start, start + 1800);
    const invalidateAt = body.indexOf("invalidatePendingRequest");
    const transferAt = body.indexOf("safeTransfer");
    assert.ok(invalidateAt > -1);
    assert.ok(transferAt > -1);
    assert.ok(invalidateAt < transferAt);

    const token = fs.readFileSync(
      path.join(__dirname, "../../../contracts/pod/token/perc20/PodERC20.sol"),
      "utf8"
    );
    assert.ok(token.includes("function invalidatePendingRequest"));
  });
});
