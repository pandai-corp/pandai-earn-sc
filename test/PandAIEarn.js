const timeMachine = require('ganache-time-traveler');
const truffleAssert = require('truffle-assertions');

const PandAI = artifacts.require("PandAI");
const USDT = artifacts.require("USDT");
const PandAIEarn = artifacts.require("PandAIEarn");

contract("pandai", function (accounts) {

    let pandai;
    let pandaiDecimals;
    let pandaiInitAmount;

    let usdt;
    let usdtDecimals;
    let usdtInitAmount;

    let pandaiEarn;

    // owner: deployer, alice: updater, bob and others: user
    let [owner, alice, bob, charlie, dan, liquidityPool] = accounts;

    const toBN = web3.utils.toBN;

    const adminRoleBytes = "0x0000000000000000000000000000000000000000000000000000000000000000";
    const updaterRoleBytes = web3.utils.keccak256("UPDATER_ROLE");

    before(async () => {
        usdt = await USDT.deployed();
        usdtDecimals = await usdt.decimals();
        usdtInitAmount = toBN(1e6).mul(toBN(10 ** usdtDecimals));

        pandai = await PandAI.deployed();
        pandaiDecimals = await pandai.decimals();
        pandaiInitAmount = toBN(1e12).mul(toBN(10 ** pandaiDecimals));

        pandaiEarn = await PandAIEarn.deployed();

        console.log("pandai: " + pandai.address);
        console.log("usdt: " + usdt.address);
        console.log("pandaiEarn: " + pandaiEarn.address);
        console.log("-----------------------------------");
        console.log("  owner: " + owner);
        console.log("  alice: " + alice);
        console.log("  bob: " + bob);
        console.log("  charlie: " + charlie);
        console.log("  dan: " + dan);
        console.log("  liquidityPool: " + liquidityPool);
        console.log("-----------------------------------");
    });

    beforeEach(async () => {
        let snapshot = await timeMachine.takeSnapshot();
        snapshotId = snapshot['result'];
    });

    describe("Time Machine", () => {

        it("can shift block.timestamp by 60 seconds and revert", async function () {
            let startTimestamp = (await web3.eth.getBlock("latest")).timestamp;
            await timeMachine.advanceTimeAndBlock(60);
            let advancedTimestamp = (await web3.eth.getBlock("latest")).timestamp;
            assert.equal(advancedTimestamp - startTimestamp, 60);

            await timeMachine.revertToSnapshot(snapshotId);
            let revertedTimestamp = (await web3.eth.getBlock("latest")).timestamp;
            assert.equal(revertedTimestamp, startTimestamp);
        });

    });

    describe("Token Distribution", () => {

        it("send usdt", async function () {
            await usdt.transfer(alice, usdtInitAmount, { from: owner });
            await usdt.transfer(bob, usdtInitAmount, { from: owner });
            await usdt.transfer(charlie, usdtInitAmount, { from: owner });
            await usdt.transfer(dan, usdtInitAmount, { from: owner });

            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(alice)));
            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(bob)));
            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(charlie)));
            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(dan)));
        });

        it("send pandai", async function () {
            await pandai.transfer(alice, pandaiInitAmount, { from: owner });
            await pandai.transfer(bob, pandaiInitAmount, { from: owner });
            await pandai.transfer(charlie, pandaiInitAmount, { from: owner });
            await pandai.transfer(dan, pandaiInitAmount, { from: owner });

            assert.isTrue(pandaiInitAmount.eq(await pandai.balanceOf(alice)));
            assert.isTrue(pandaiInitAmount.eq(await pandai.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.eq(await pandai.balanceOf(charlie)));
            assert.isTrue(pandaiInitAmount.eq(await pandai.balanceOf(dan)));
        });

        it("init liquidity pool", async function () {
            let usdtInitAmount = toBN(1).mul(toBN(10 ** usdtDecimals));
            let pandaiInitAmount = toBN(1e6).mul(toBN(10 ** pandaiDecimals));

            await usdt.transfer(liquidityPool, usdtInitAmount, { from: owner });
            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(liquidityPool)));

            await pandai.transfer(liquidityPool, pandaiInitAmount, { from: owner });
            assert.isTrue(pandaiInitAmount.eq(await pandai.balanceOf(liquidityPool)));
        });

    });

    describe("Admin Role", () => {

        it("owner has admin role", async function () {
            assert.isTrue(await pandaiEarn.hasRole(adminRoleBytes, owner));
            assert.isFalse(await pandaiEarn.hasRole(adminRoleBytes, alice));
            assert.isFalse(await pandaiEarn.hasRole(adminRoleBytes, bob));
        });

        it("admin can add admin", async function () {
            await pandaiEarn.grantRole(adminRoleBytes, alice, { from: owner });
            assert.isTrue(await pandaiEarn.hasRole(adminRoleBytes, owner));
            assert.isTrue(await pandaiEarn.hasRole(adminRoleBytes, alice));
            assert.isFalse(await pandaiEarn.hasRole(adminRoleBytes, bob));
        });

        it("admin can remove admin", async function () {
            await pandaiEarn.revokeRole(adminRoleBytes, alice, { from: owner });
            assert.isTrue(await pandaiEarn.hasRole(adminRoleBytes, owner));
            assert.isFalse(await pandaiEarn.hasRole(adminRoleBytes, alice));
            assert.isFalse(await pandaiEarn.hasRole(adminRoleBytes, bob));
        });

        it("non-admin cannot edit admin", async function () {
            await truffleAssert.reverts(pandaiEarn.grantRole(adminRoleBytes, alice, { from: alice }));
            await truffleAssert.reverts(pandaiEarn.revokeRole(adminRoleBytes, owner, { from: alice }));
        });

        it("admin can set liquidity pool", async function () {
            await pandaiEarn.setLpAddress(liquidityPool, { from: owner });
            await truffleAssert.reverts(pandaiEarn.setLpAddress(liquidityPool, { from: alice }));
            assert.equal(liquidityPool, await pandaiEarn.getLpAddress());
        });

        it("admin can deposit and withdraw treasury", async function () {
            let usdtAmount = toBN(1e6).mul(toBN(10 ** usdtDecimals));

            await usdt.approve(pandaiEarn.address, usdtAmount.mul(toBN(2)), { from: owner });
            await pandaiEarn.depositTreasury(usdtAmount.mul(toBN(2)), { from: owner });
            assert.isTrue(usdtAmount.mul(toBN(2)).eq(await usdt.balanceOf(pandaiEarn.address)));

            await truffleAssert.reverts(pandaiEarn.withdrawTreasury(usdtAmount, { from: alice }));
            await pandaiEarn.withdrawTreasury(usdtAmount, { from: owner });
            assert.isTrue(usdtAmount.eq(await usdt.balanceOf(pandaiEarn.address)));
        });

        it("admin can pause contract", async function () {
            await pandaiEarn.pause({ from: owner });
            assert.isTrue(await pandaiEarn.paused({ from: owner }));
            await pandaiEarn.unpause({ from: owner });
            assert.isFalse(await pandaiEarn.paused({ from: owner }));

            await truffleAssert.reverts(pandaiEarn.pause({ from: alice }));
        });

    });

    describe("Updater Role", () => {

        it("admin can add updater", async function () {
            await pandaiEarn.grantRole(updaterRoleBytes, alice, { from: owner });
            await pandaiEarn.grantRole(updaterRoleBytes, bob, { from: owner });
            assert.isFalse(await pandaiEarn.hasRole(updaterRoleBytes, owner));
            assert.isTrue(await pandaiEarn.hasRole(updaterRoleBytes, alice));
            assert.isTrue(await pandaiEarn.hasRole(updaterRoleBytes, bob));
        });

        it("admin can remove updater", async function () {
            await pandaiEarn.revokeRole(updaterRoleBytes, bob, { from: owner });
            assert.isFalse(await pandaiEarn.hasRole(updaterRoleBytes, owner));
            assert.isTrue(await pandaiEarn.hasRole(updaterRoleBytes, alice));
            assert.isFalse(await pandaiEarn.hasRole(updaterRoleBytes, bob));
        });

        it("non-admin cannot edit updater", async function () {
            await truffleAssert.reverts(pandaiEarn.grantRole(updaterRoleBytes, bob, { from: alice }));
            await truffleAssert.reverts(pandaiEarn.revokeRole(updaterRoleBytes, alice, { from: alice }));
        });

        it("only updater can change approval level", async function () {
            await truffleAssert.reverts(pandaiEarn.setUserApprovalLevel(bob, 1, { from: owner }));
            await truffleAssert.reverts(pandaiEarn.setUserApprovalLevel(bob, 1, { from: bob }));

            await pandaiEarn.setUserApprovalLevel(bob, 1, { from: alice });
            let userBob = await pandaiEarn.getUser(bob);
            assert.equal(userBob.stored.approvalLevel, 1);
        });

        it("only approval:0,1,2 can be set", async function () {
            await pandaiEarn.setUserApprovalLevel(bob, 0, { from: alice });
            await pandaiEarn.setUserApprovalLevel(bob, 1, { from: alice });
            await pandaiEarn.setUserApprovalLevel(bob, 2, { from: alice });
            await truffleAssert.reverts(pandaiEarn.setUserApprovalLevel(bob, 3, { from: alice }));
            await pandaiEarn.setUserApprovalLevel(bob, 1, { from: alice });
        });

    });

    describe("Deposit", () => {

        it("second deposit", async function () {
            let usdtDeposit = toBN(100).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(2).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(0.2e6).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // second deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit.mul(toBN(2))).eq(await usdt.balanceOf(bob)));

            // advance for another 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit.mul(toBN(2))).add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("cannot deposit when paused", async function () {
            let usdtDeposit = toBN(100).mul(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            await pandaiEarn.pause({ from: owner });
            await truffleAssert.reverts(pandaiEarn.deposit(usdtDeposit, { from: bob }));

            await timeMachine.revertToSnapshot(snapshotId);
        });

    });

    describe("Claim", () => {

        it("claim in 30 days and 30 days after works the same", async function () {
            let usdtDeposit = toBN(100).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(1).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(0.1e6).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // claim
            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for another 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // claim
            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtReward.mul(toBN(2))).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn.mul(toBN(2))).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("NotApproved - daily claim limit", async function () {
            // reward: $60 per month
            let usdtDeposit = toBN(4000).mul(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // NotApproved, deposit 
            await pandaiEarn.setUserApprovalLevel(bob, 0, { from: alice });
            await pandaiEarn.deposit(usdtDeposit, { from: bob });

            // advance for 18 * 30 days (reward > $1000)
            await timeMachine.advanceTimeAndBlock(18 * 30 * 86400);

            await truffleAssert.reverts(pandaiEarn.claim({ from: bob }));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("Approved - no claim limit", async function () {
            // reward: $60 per month
            let usdtDeposit = toBN(4000).mul(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // Approved, deposit
            await pandaiEarn.setUserApprovalLevel(bob, 1, { from: alice });
            await pandaiEarn.deposit(usdtDeposit, { from: bob });

            // advance for 18 * 30 days (reward > $1000)
            await timeMachine.advanceTimeAndBlock(18 * 30 * 86400);

            await truffleAssert.passes(pandaiEarn.claim({ from: bob }));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("Forbidden - claim forbidden", async function () {
            // reward: $60 per month
            let usdtDeposit = toBN(4000).mul(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // Forbidden, deposit
            await pandaiEarn.setUserApprovalLevel(bob, 2, { from: alice });
            await pandaiEarn.deposit(usdtDeposit, { from: bob });

            // advance for 1 days
            await timeMachine.advanceTimeAndBlock(86400);

            await truffleAssert.reverts(pandaiEarn.claim({ from: bob }));

            await timeMachine.revertToSnapshot(snapshotId);
        });

    });

    describe("Withdraw", () => {

        it("resulting balance cannot be > 0 and ≤ 100 USDT", async function () {
            let usdtDeposit = toBN(100).mul(toBN(10 ** usdtDecimals));
            let usdtWithdraw = toBN(50).mul(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // requesting withdraw
            await truffleAssert.reverts(pandaiEarn.requestWithdraw(usdtWithdraw, { from: bob }));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("request takes 14 days to process", async function () {
            let usdtDeposit = toBN(100).mul(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });

            // advance for 14 days - 1 second
            await timeMachine.advanceTimeAndBlock(14 * 86400 - 1);
            await truffleAssert.reverts(pandaiEarn.withdraw({ from: bob }));

            // advance for 1 second
            await timeMachine.advanceTimeAndBlock(1);
            await pandaiEarn.withdraw({ from: bob });

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("request withdraw when there's already a request increases withdraw amount", async function () {
            let usdtDeposit = toBN(400).mul(toBN(10 ** usdtDecimals));
            let usdtWithdraw = toBN(100).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(3).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(0.3e6).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);
            await pandaiEarn.requestWithdraw(usdtWithdraw, { from: bob });

            // advance for 10 days
            await timeMachine.advanceTimeAndBlock(10 * 86400);
            await pandaiEarn.requestWithdraw(usdtWithdraw, { from: bob });

            // advance for 20 days
            await timeMachine.advanceTimeAndBlock(20 * 86400);
            await pandaiEarn.requestWithdraw(usdtWithdraw, { from: bob });

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtWithdraw.mul(toBN(3))).eq(await usdt.balanceOf(bob)));

            // claim
            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtWithdraw.mul(toBN(3))).add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("request withdraw reduces claim reward", async function () {
            let usdtDeposit = toBN(200).mul(toBN(10 ** usdtDecimals));
            let usdtWithdraw = toBN(100).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(2).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(0.2e6).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            await pandaiEarn.requestWithdraw(usdtWithdraw, { from: bob });

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // claim
            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

    });

    describe("Referral", () => {

        it("address cannot reffer itself", async function () {
            let usdtDeposit = toBN(100).mul(toBN(10 ** usdtDecimals));
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await truffleAssert.reverts(pandaiEarn.depositWithReferral(usdtDeposit, bob, { from: bob }));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("re-set referral doesn't do anything", async function () {
            let usdtDeposit = toBN(1000).mul(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            await pandaiEarn.depositWithReferral(usdtDeposit, charlie, { from: bob });
            let userBob = await pandaiEarn.getUser(bob, { from: bob });
            assert.equal(userBob.stored.referral, charlie);

            await pandaiEarn.depositWithReferral(usdtDeposit, dan, { from: bob });
            userBob = await pandaiEarn.getUser(bob, { from: bob });
            assert.equal(userBob.stored.referral, charlie);

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("no referral sets defaults", async function () {
            let usdtDeposit = toBN(1000).mul(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            let userBob = await pandaiEarn.getUser(bob, { from: bob });
            assert.equal(userBob.stored.referral, "0xEe9Aa828fF4cBF294063168E78BEB7BcF441fEa1");

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("repeated claim works the same", async function () {
            let usdtDeposit = toBN(1000).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(2).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(0.2e6).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(charlie), { from: charlie });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(charlie), { from: charlie });

            await pandaiEarn.depositWithReferral(usdtDeposit, bob, { from: charlie });

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for another 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.add(usdtReward.mul(toBN(2))).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn.mul(toBN(2))).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("additional deposits increase referral deposit", async function () {
            let usdtDeposit = toBN(1000).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(6).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(0.6e6).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(charlie), { from: charlie });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(charlie), { from: charlie });

            await pandaiEarn.depositWithReferral(usdtDeposit, bob, { from: charlie });

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);
            await pandaiEarn.deposit(usdtDeposit, { from: charlie });

            // advance for another 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("withdraw request decreases referral deposit", async function () {
            let usdtDeposit = toBN(1000).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(6).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(0.6e6).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(charlie), { from: charlie });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(charlie), { from: charlie });

            await pandaiEarn.depositWithReferral(usdtDeposit.mul(toBN(2)), bob, { from: charlie });

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: charlie });

            // advance for another 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

    });

    describe("Tier1 Params", () => {

        it("claim after 30 days and withdraw", async function () {
            let usdtDeposit = toBN(100).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(1).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(0.1e6).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // claim
            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("withdraw after 6 days comes with fee", async function () {
            let usdtDeposit = toBN(100).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(40e6).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 6 days
            await timeMachine.advanceTimeAndBlock(6 * 86400);

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

    });

    describe("Tier2 Params", () => {

        it("claim after 30 days and withdraw", async function () {
            let usdtDeposit = toBN(800).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(10).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(10).mul(toBN(0.09e6)).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // claim
            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("withdraw after 29 days comes with fee", async function () {
            let usdtDeposit = toBN(800).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(800).mul(toBN(0.35e6)).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 29 days
            await timeMachine.advanceTimeAndBlock(29 * 86400);

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

    });

    describe("Tier3 Params", () => {

        it("claim after 30 days, withdraw after 60 days", async function () {
            let usdtDeposit = toBN(1000).mul(toBN(10 ** usdtDecimals));
            let usdtReward = toBN(15).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(15).mul(toBN(0.08e6)).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // claim
            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for additional 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("withdraw after 59 days comes with fee", async function () {
            let usdtDeposit = toBN(1000).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(1000).mul(toBN(0.3e6)).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 59 days
            await timeMachine.advanceTimeAndBlock(59 * 86400);

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

    });

    describe("Tier4 Params", () => {

        it("claim after 30 days, withdraw after 90 days", async function () {
            let usdtDeposit = toBN(5000).mul(toBN(10 ** usdtDecimals));

            let g = toBN(180);
            let f1 = usdtDeposit.mul(g).div(toBN(1e4));
            let f2 = f1.mul(g).div(toBN(1e4)).div(toBN(2));
            let f3 = f2.mul(g).div(toBN(1e4)).div(toBN(3));
            let usdtReward = f1.add(f2).add(f3);
            let pandaiBurn = usdtReward.mul(toBN(0.065e6)).mul(toBN(10 ** pandaiDecimals)).div(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // claim
            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for additional 60 days
            await timeMachine.advanceTimeAndBlock(60 * 86400);

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("withdraw after 89 days comes with fee", async function () {
            let usdtDeposit = toBN(5000).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(5000).mul(toBN(0.25e6)).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 89 days
            await timeMachine.advanceTimeAndBlock(89 * 86400);

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

    });

    describe("Tier5 Params", () => {

        it("claim after 30 days, withdraw after 180 days", async function () {
            let usdtDeposit = toBN(10000).mul(toBN(10 ** usdtDecimals));

            let g = toBN(220);
            let f1 = usdtDeposit.mul(g).div(toBN(1e4));
            let f2 = f1.mul(g).div(toBN(1e4)).div(toBN(2));
            let f3 = f2.mul(g).div(toBN(1e4)).div(toBN(3));
            let usdtReward = f1.add(f2).add(f3);
            let pandaiBurn = usdtReward.mul(toBN(0.05e6)).mul(toBN(10 ** pandaiDecimals)).div(toBN(10 ** usdtDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 30 days
            await timeMachine.advanceTimeAndBlock(30 * 86400);

            // claim
            await pandaiEarn.claim({ from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for additional 150 days
            await timeMachine.advanceTimeAndBlock(150 * 86400);

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.add(usdtReward).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

        it("withdraw after 179 days comes with fee", async function () {
            let usdtDeposit = toBN(10000).mul(toBN(10 ** usdtDecimals));
            let pandaiBurn = toBN(10000).mul(toBN(0.2e6)).mul(toBN(10 ** pandaiDecimals));

            // approvals
            await usdt.approve(pandaiEarn.address, await usdt.balanceOf(bob), { from: bob });
            await pandai.approve(pandaiEarn.address, await pandai.balanceOf(bob), { from: bob });

            // deposit
            await pandaiEarn.deposit(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));

            // advance for 179 days
            await timeMachine.advanceTimeAndBlock(179 * 86400);

            // requesting withdraw
            await pandaiEarn.requestWithdraw(usdtDeposit, { from: bob });
            assert.isTrue(usdtInitAmount.sub(usdtDeposit).eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            // advance for 14 days
            await timeMachine.advanceTimeAndBlock(14 * 86400);

            // withdraw
            await pandaiEarn.withdraw({ from: bob });
            assert.isTrue(usdtInitAmount.eq(await usdt.balanceOf(bob)));
            assert.isTrue(pandaiInitAmount.sub(pandaiBurn).eq(await pandai.balanceOf(bob)));

            await timeMachine.revertToSnapshot(snapshotId);
        });

    });


});