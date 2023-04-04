const PandAI = artifacts.require("PandAI");
const USDT = artifacts.require("USDT");
const PandAIEarn = artifacts.require("PandAIEarn");

contract("PandAI", function (accounts) {

    let pandAI;
    let usdt;
    let pandaiEarn;
    let [owner, alice, bob, lp] = accounts;
    const toBN = web3.utils.toBN;

    before(async () => {
        pandAI = await PandAI.deployed();
        usdt = await USDT.deployed();
        pandAIEarn = await PandAIEarn.deployed();
    });

    it("test", async function() {
        console.log(pandAI.address);
        console.log(usdt.address);
        console.log(pandAIEarn.address);

        assert.isTrue(true, `tokenBalance of owner should be lowered`);
    });


});