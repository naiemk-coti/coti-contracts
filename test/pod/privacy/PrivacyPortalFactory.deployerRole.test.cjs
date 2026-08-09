/**
 * Factory deploy rights are AccessControl DEPLOYER_ROLE (not a free mapping).
 * Run: `node --test test/pod/privacy/PrivacyPortalFactory.deployerRole.test.cjs`
 */
const assert = require("node:assert/strict");
const { describe, it } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

describe("PrivacyPortalFactory deployer role", () => {
  it("gates createPortal on DEPLOYER_ROLE grant/revoke", () => {
    const src = fs.readFileSync(
      path.join(__dirname, "../../../contracts/pod/privacy/PrivacyPortalFactory.sol"),
      "utf8"
    );
    assert.ok(src.includes('keccak256("DEPLOYER_ROLE")'));
    assert.ok(src.includes("hasRole(DEPLOYER_ROLE, msg.sender)"));
    assert.ok(src.includes("_grantRole(DEPLOYER_ROLE"));
    assert.ok(src.includes("_revokeRole(DEPLOYER_ROLE"));
    assert.ok(src.includes("function deployers(address account)"));
    assert.equal(/mapping\(address => bool\) public deployers/.test(src), false);
  });
});
