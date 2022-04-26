import * as dotenv from "dotenv";

import { HardhatUserConfig } from "hardhat/config";
import "@typechain/hardhat";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.5.16",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      }
    ],
  },
  networks: {
    hardhat: {
      accounts: {
        mnemonic: process.env.MNEMONIC,
      },
    },
  }
};

export default config;
