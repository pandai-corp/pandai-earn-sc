const PandAI = artifacts.require("PandAI");
const USDT = artifacts.require("USDT");
const PandAIEarn = artifacts.require("PandAIEarn");

module.exports = async function (deployer) {
  let pandaiInstance = await PandAI.deployed(PandAI);
  let usdtInstance = await USDT.deployed(USDT);
  await deployer.deploy(PandAIEarn, pandaiInstance.address, usdtInstance.address);
};