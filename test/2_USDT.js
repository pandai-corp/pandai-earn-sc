const USDT = artifacts.require("USDT");

contract("USDT", function (accounts) {

    let usdt;
    let usdtDecimals;
    let [owner, alice, bob] = accounts;
    const toBN = web3.utils.toBN;

    before(async () => {
        usdt = await USDT.deployed();
        usdtDecimals = await usdt.decimals();    
    });

    it("only deployer owns tokens", async function() {
        console.log(usdt.address);

        assert.isTrue(toBN(await usdt.balanceOf(owner)).eq(toBN(await usdt.totalSupply())), `tokenBalance of owner should be totalSupply`);
        assert.equal(await usdt.balanceOf(alice), 0, `tokenBalance of alice should be 0`);
        assert.equal(await usdt.balanceOf(bob), 0, `tokenBalance of bob should be 0`);
    });

    describe("Transfers", () => {

        it("transferToAlice", async () => {
            let transferAmount = toBN(1000).mul(toBN(10 ** usdtDecimals));
            await usdt.transfer(alice, transferAmount, {from: owner});
            assert.isTrue(toBN(await usdt.balanceOf(owner)).eq(toBN(await usdt.totalSupply()).sub(transferAmount)), `tokenBalance of owner should be lowered`);
            assert.isTrue(toBN(await usdt.balanceOf(alice)).eq(transferAmount), `tokenBalance of Alice should be increased`);
            assert.equal(await usdt.balanceOf(bob), 0, `tokenBalance of bob should be 0`);
        });
       
    });

});