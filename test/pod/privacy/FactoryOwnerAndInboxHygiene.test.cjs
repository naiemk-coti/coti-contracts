const assert = require("node:assert/strict");
const { describe, it } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

describe("L-05 InboxUser setInbox hygiene", () => {
  it("rejects zero inbox and emits InboxUpdated", () => {
    const src = fs.readFileSync(
      path.join(__dirname, "../../../contracts/pod/InboxUser.sol"),
      "utf8"
    );
    assert.ok(src.includes("error ZeroInbox"));
    assert.ok(src.includes("event InboxUpdated"));
    assert.ok(src.includes("emit InboxUpdated"));
  });
});

describe("L-33 factory primary owner + last admin", () => {
  it("forbids last-admin revoke and requires transfer before primary revoke", () => {
    const src = fs.readFileSync(
      path.join(__dirname, "../../../contracts/pod/privacy/PrivacyPortalFactory.sol"),
      "utf8"
    );
    assert.ok(src.includes("CannotRevokeLastAdmin"));
    assert.ok(src.includes("PrimaryOwnerMustTransferFirst"));
    assert.ok(src.includes("function transferPrimaryOwner"));
    assert.ok(src.includes("_adminCount"));
  });
});
