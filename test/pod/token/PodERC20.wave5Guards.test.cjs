/**
 * Wave 5 source-order guards for PodERC20 / mother / factory / oracle.
 * Run: `node --test test/pod/token/PodERC20.wave5Guards.test.cjs`
 */
const assert = require("node:assert/strict");
const { describe, it } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "../../..");
const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8");

describe("Wave 5 portal/pToken guards", () => {
  it("L-27: factory impl/oracle setters require code when non-zero", () => {
    const src = read("contracts/pod/privacy/PrivacyPortalFactory.sol");
    assert.ok(src.includes("ImplementationHasNoCode"));
    assert.ok(src.includes("portalImplementation_.code.length == 0"));
    assert.ok(src.includes("podTokenImplementation_.code.length == 0"));
    assert.ok(src.includes("newOracle != address(0) && newOracle.code.length == 0"));
  });

  it("L-29: UnwrapFinalized uses uint256 cleartextAmount", () => {
    const iface = read("contracts/pod/token/erc7984/IERC7984PortalWrapper.sol");
    const portal = read("contracts/pod/privacy/PrivacyPortal.sol");
    assert.ok(iface.includes("uint256 cleartextAmount"));
    assert.ok(!iface.includes("uint64 cleartextAmount"));
    assert.ok(portal.includes("withdrawal.amount"));
    assert.ok(!portal.includes("uint64(withdrawal.amount)"));
  });

  it("L-30: BalanceSyncSkipped on stale nonce paths", () => {
    const src = read("contracts/pod/token/perc20/PodERC20.sol");
    assert.ok(src.includes("emit BalanceSyncSkipped"));
    assert.equal((src.match(/emit BalanceSyncSkipped/g) || []).length >= 3, true);
  });

  it("L-31: killStaleRequest + requestCreatedAt on Pending", () => {
    const src = read("contracts/pod/token/perc20/PodERC20.sol");
    assert.ok(src.includes("function killStaleRequest"));
    assert.ok(src.includes("RequestNotAged"));
    assert.ok(src.includes("requestCreatedAt[requestId] = uint64(block.timestamp)"));
    assert.ok(src.includes("emit StaleRequestKilled"));
  });

  it("L-31 factory: admin forwarders for factory-owned pToken admin ops", () => {
    const factory = read("contracts/pod/privacy/PrivacyPortalFactory.sol");
    const admin = read("contracts/pod/privacy/IPrivacyPortalFactoryAdmin.sol");
    assert.ok(factory.includes("function setPTokenMinter"));
    assert.ok(factory.includes("function setPTokenRequestKillMinAge"));
    assert.ok(factory.includes("function killPTokenStaleRequest"));
    assert.ok(admin.includes("function setPTokenMinter"));
    assert.ok(admin.includes("function setPTokenRequestKillMinAge"));
    assert.ok(admin.includes("function killPTokenStaleRequest"));
    const ptoken = read("contracts/pod/token/perc20/PodERC20.sol");
    assert.ok(ptoken.includes("function renounceOwnership"));
    assert.ok(ptoken.includes("OwnershipCannotBeRenounced"));
  });

  it("L-32: mother allowance-less paths renamed; permit uses transferOwnerPublic", () => {
    const mother = read("contracts/pod/token/perc20/cotiside/PodErc20CotiMother.sol");
    const iface = read("contracts/pod/token/perc20/cotiside/IPodErc20CotiSide.sol");
    const ptoken = read("contracts/pod/token/perc20/PodERC20.sol");
    assert.ok(mother.includes("function transferOwnerPublic"));
    assert.ok(iface.includes("function transferOwnerPublic"));
    assert.ok(!mother.includes("function transferFromPublic("));
    assert.ok(ptoken.includes("transferOwnerPublic.selector"));
    assert.ok(ptoken.includes("transferFromPublicAsSpender.selector"));
  });

  it("L-34: PortalFeeOracle meta + clear", () => {
    const src = read("contracts/pod/privacy/PortalFeeOracle.sol");
    assert.ok(src.includes("tokenPriceUpdatedAt"));
    assert.ok(src.includes("function clearTokenPriceUSD"));
    assert.ok(src.includes("function getTokenPriceMeta"));
  });

  it("L-35: lastConfidentialTransferHandle removed", () => {
    const src = read("contracts/pod/token/erc7984/PodErc7984Mixin.sol");
    assert.ok(!src.includes("lastConfidentialTransferHandle"));
  });
});
