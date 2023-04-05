const PandAI = artifacts.require("PandAI");
const USDT = artifacts.require("USDT");
const PandAIEarn = artifacts.require("PandAIEarn");

module.exports = async function (deployer) {
  await deployer.deploy(PandAI);
  await deployer.deploy(USDT);
  await deployer.deploy(PandAIEarn, PandAI.address, USDT.address);
};