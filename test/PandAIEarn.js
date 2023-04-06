const timeMachine = require('ganache-time-traveler');
const truffleAssert = require('truffle-assertions');

const PandAI = artifacts.require("PandAI");
const USDT = artifacts.require("USDT");
const PandAIEarn = artifacts.require("PandAIEarn");

contract("PandAI", function (accounts) {

    let pandAI;
    let usdt;
    let pandAIEarn;
    let [owner, alice, bob] = accounts;
    const toBN = web3.utils.toBN;


    const adminRoleBytes = "0x0000000000000000000000000000000000000000000000000000000000000000";
    const updaterRoleBytes = web3.utils.keccak256("UPDATER_ROLE");

    before(async () => {
        pandAI = await PandAI.deployed();
        usdt = await USDT.deployed();
        pandAIEarn = await PandAIEarn.deployed();
    });

    beforeEach(async() => {
        let snapshot = await timeMachine.takeSnapshot();
        snapshotId = snapshot['result'];
    });
 
    describe("Time Machine", () => {

        it("can shift block.timestamp by 60 seconds", async function() {
            let currTimestamp = (await web3.eth.getBlock("latest")).timestamp;
            await timeMachine.advanceTimeAndBlock(60);
            let advancedTimestamp = (await web3.eth.getBlock("latest")).timestamp;
            assert.equal(advancedTimestamp - currTimestamp, 60);
            
            await timeMachine.revertToSnapshot(snapshotId);
        });

    });

    describe("Admin Role", () => {
    
        it("owner has admin role", async function() {
            assert.isTrue(await pandAIEarn.hasRole(adminRoleBytes, owner));
            assert.isFalse(await pandAIEarn.hasRole(adminRoleBytes, alice));
            assert.isFalse(await pandAIEarn.hasRole(adminRoleBytes, bob));
        });

        it("admin can add admin", async function() {
            await pandAIEarn.grantRole(adminRoleBytes, alice, {from: owner});
            assert.isTrue(await pandAIEarn.hasRole(adminRoleBytes, owner));
            assert.isTrue(await pandAIEarn.hasRole(adminRoleBytes, alice));
            assert.isFalse(await pandAIEarn.hasRole(adminRoleBytes, bob));
        });

        it("admin can remove admin", async function() {
            await pandAIEarn.revokeRole(adminRoleBytes, alice, {from: owner});
            assert.isTrue(await pandAIEarn.hasRole(adminRoleBytes, owner));
            assert.isFalse(await pandAIEarn.hasRole(adminRoleBytes, alice));
            assert.isFalse(await pandAIEarn.hasRole(adminRoleBytes, bob));
        });

        it("non-admin cannot edit admin", async function() {
            await truffleAssert.reverts(pandAIEarn.grantRole(adminRoleBytes, alice, {from: alice}));
            await truffleAssert.reverts(pandAIEarn.revokeRole(adminRoleBytes, owner, {from: alice}));
        });

    });

    describe("Updater Role", () => {

        it("admin can add updater", async function() {
            await pandAIEarn.grantRole(updaterRoleBytes, alice, {from: owner});
            await pandAIEarn.grantRole(updaterRoleBytes, bob, {from: owner});
            assert.isFalse(await pandAIEarn.hasRole(updaterRoleBytes, owner));
            assert.isTrue(await pandAIEarn.hasRole(updaterRoleBytes, alice));
            assert.isTrue(await pandAIEarn.hasRole(updaterRoleBytes, bob));
        });

        it("admin can remove updater", async function() {
            await pandAIEarn.revokeRole(updaterRoleBytes, bob, {from: owner});
            assert.isFalse(await pandAIEarn.hasRole(updaterRoleBytes, owner));
            assert.isTrue(await pandAIEarn.hasRole(updaterRoleBytes, alice));
            assert.isFalse(await pandAIEarn.hasRole(updaterRoleBytes, bob));
        });

        it("non-admin cannot edit updater", async function() {
            await truffleAssert.reverts(pandAIEarn.grantRole(updaterRoleBytes, bob, {from: alice}));
            await truffleAssert.reverts(pandAIEarn.revokeRole(updaterRoleBytes, alice, {from: alice}));
        });

    });

});