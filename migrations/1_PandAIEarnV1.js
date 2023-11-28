const PandAI = artifacts.require("PandAI");
const USDT = artifacts.require("USDT");

const PandAIEarnV1 = artifacts.require("PandAIEarnV1");
const PandAIEarnV1_1 = artifacts.require("PandAIEarnV1_1");

module.exports = async function (deployer) {
  await deployer.deploy(USDT);
  await deployer.deploy(PandAI);
  
  await deployer.deploy(PandAIEarnV1, USDT.address, PandAI.address);
  await deployer.deploy(PandAIEarnV1_1, USDT.address, PandAI.address);
};