const PandAI = artifacts.require("PandAI");

contract("PandAI", function (accounts) {

    let pandAI;
    let pandAIDecimals;
    let [owner, alice, bob] = accounts;
    const toBN = web3.utils.toBN;

    before(async () => {
        pandAI = await PandAI.deployed();
        pandAIDecimals = await pandAI.decimals();
    });

    it("only deployer owns tokens", async function() {
        console.log(pandAI.address);

        assert.isTrue(toBN(await pandAI.balanceOf(owner)).eq(toBN(await pandAI.totalSupply())), `tokenBalance of owner should be totalSupply`);
        assert.equal(await pandAI.balanceOf(alice), 0, `tokenBalance of alice should be 0`);
        assert.equal(await pandAI.balanceOf(bob), 0, `tokenBalance of bob should be 0`);
    });

    describe("Transfers", () => {

        it("transferToAlice", async () => {
            let transferAmount = toBN(1000).mul(toBN(10 ** pandAIDecimals));
            await pandAI.transfer(alice, transferAmount, {from: owner});
            assert.isTrue(toBN(await pandAI.balanceOf(owner)).eq(toBN(await pandAI.totalSupply()).sub(transferAmount)), `tokenBalance of owner should be lowered`);
            assert.isTrue(toBN(await pandAI.balanceOf(alice)).eq(transferAmount), `tokenBalance of Alice should be increased`);
            assert.equal(await pandAI.balanceOf(bob), 0, `tokenBalance of bob should be 0`);
        });
       
    });

});