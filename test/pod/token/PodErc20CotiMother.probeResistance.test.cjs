/**
 * Regression notes for confidential-balance probe resistance on public spender paths.
 *
 * Invariant (PodErc20CotiMother._moveWithOptionalAllowance, public spender path):
 * 1. Allowance / auth is evaluated before any balance comparison.
 * 2. Unapproved probes and insufficient-balance failures (when allowance was checked) share the
 *    single public reason `PodErc20CotiMother: transfer failed` so callers cannot binary-search
 *    balances via distinct TransferFailed strings.
 * 3. Encrypted (non-public) amounts still mux to zero and always Success — no public reason leak.
 *
 * Full MPC round-trip coverage lives in pod-ecosystem-integration system tests on COTI.
 * Run: `node --test test/pod/token/PodErc20CotiMother.probeResistance.test.cjs`
 */
const assert = require("node:assert/strict");
const { describe, it } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

describe("PodErc20CotiMother public spender probe resistance", () => {
  it("source evaluates allowance before balance and unifies public spender failure reasons", () => {
    const src = fs.readFileSync(
      path.join(__dirname, "../../../contracts/pod/token/perc20/cotiside/PodErc20CotiMother.sol"),
      "utf8"
    );
    const fnStart = src.indexOf("function _moveWithOptionalAllowance");
    assert.ok(fnStart > -1);
    const body = src.slice(fnStart, fnStart + 4500);

    const allowanceCheck = body.indexOf("_readGarbledAllowance");
    const balanceDecryptPublic = body.indexOf("MpcCore.ge(senderBalance, amount)");
    assert.ok(allowanceCheck > -1);
    assert.ok(balanceDecryptPublic > -1);
    assert.ok(allowanceCheck < balanceDecryptPublic);

    assert.ok(body.includes('bytes("PodErc20CotiMother: transfer failed")'));
    assert.equal(/insufficient allowance/.test(body), false);
  });
});
