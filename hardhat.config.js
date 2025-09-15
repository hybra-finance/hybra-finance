require("@nomiclabs/hardhat-waffle");
require('@openzeppelin/hardhat-upgrades');
require("@nomiclabs/hardhat-etherscan");
require("@nomiclabs/hardhat-web3");
require("hardhat-contract-sizer");
require("dotenv").config(); 

module.exports = {
  // Latest Solidity version
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },
  solidity: {
    compilers: [
      {
        version: "0.8.13",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
          },
          metadata: {
              useLiteralContent: true
          }
        },
      },
    ],
  },

  networks: {
    hyper: {
      url: "https://rpc.hyperliquid.xyz/evm",
      chainId: 999,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      gas: 30000000,
      blockGasLimit: 30000000,
      timeout: 1800000
    },
  },

  etherscan: {
    apiKey: `${process.env.APIKEY}`,
  },

  mocha: {
    timeout: 100000000,
  },
  contractSizer: {
    runOnCompile: true
},
};
