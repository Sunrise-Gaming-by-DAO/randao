const Web3                        = require('web3');
const ContractDeployerWithTruffle = require('@evmchain/contract-deployer/src/truffle');
const { networks }                = require('../truffle-config.js');

module.exports = async function (deployer, network, accounts) {
  const { provider } = (networks[network] || {})
  if (!provider) {
    throw new Error(`Unable to find provider for network: ${network}`)
  }

  const web3 = new Web3(provider);
  const deployConfig = {
    dataFilename: `./network/${network}.json`,
    deployData: require(`../network/${network}.json`),
    proxyAdminName: "SuncProxyAdmin",
    proxyName: "SuncProxy"
  }

  const contractDeployer = new ContractDeployerWithTruffle({artifacts, deployer});
  contractDeployer.setWeb3(web3);
  contractDeployer.setConfig(deployConfig);

  // Initialize
  await contractDeployer.init();
  // Deploy contract
  await contractDeployer.deployAllManifests({
    args: {
      SunriseRandao: { 
        initArgs: [
          "config:randao.period", 
          "config:randao.rewardPerBlock", 
          "config:randao.tokenDuration", 
          "config:susd.address", 
          "config:randao.signer",
          "config:randao.manager"
        ] 
      },
      RandaoStaking: {
        initArgs: [
          "config:sunc.address",
          "config:staking.minAmount"
        ]
      }
    }
  });

  if (deployConfig.deployData.contracts.SunriseRandao != undefined) {

    // Grant roles
    await contractDeployer.grantRoles();

    // Setting Randao
    let contractRandao = await contractDeployer.loadContract('SunriseRandao');
    
    let randaoPeriod = contractDeployer.formatValue("config:randao.period");
    let randaoRewardPerBlock = contractDeployer.formatValue("config:randao.rewardPerBlock");
    let randaoTokenDuration = contractDeployer.formatValue("config:randao.tokenDuration");
    console.log('randaoPeriod :>> ', randaoPeriod);
    console.log('randaoRewardPerBlock :>> ', randaoRewardPerBlock);
    console.log('randaoTokenDuration :>> ', randaoTokenDuration);

    let scRandaoPeriod = await contractRandao.RANDAO_PERIOD();
    if (randaoPeriod != scRandaoPeriod) {
      console.log('- Updating randaoPeriod', scRandaoPeriod.toString(), ' => ', randaoPeriod);
      let tx = await contractRandao.setRandaoPeriod(randaoPeriod);
      console.log(' -> txId :>> ', tx.tx);
    }

  }

  if (deployConfig.deployData.contracts.RandaoStaking != undefined) {
    // Setting RandaoStaking
    let contractStaking = await contractDeployer.loadContract('RandaoStaking');

    let minStakeAmount = contractDeployer.formatValue("config:staking.minAmount");
    console.log("staking.minAmount: >>", minStakeAmount);

    let scMinStakeAmount = await contractStaking.MIN_STAKE_AMOUNT();
    if (scMinStakeAmount != minStakeAmount) {
      console.log('- Updating minStakeAmount', scMinStakeAmount.toString(), ' => ', minStakeAmount);
      let tx = await contractStaking.setMinStakeAmount(minStakeAmount);
      console.log(' -> txID :>>', tx.tx);
    }
  }
}
