require('@nomiclabs/hardhat-waffle')
require('@nomiclabs/hardhat-web3')
require("solidity-coverage")
require("@tenderly/hardhat-tenderly")

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
    networks: {
        local: {
            url: 'http://localhost:8545'
        }
    },
    solidity: {
        version: '0.6.11',
    },
    tenderly: {
		username: 'atvanguard',
		project: 'hardhat-debug'
	}
}
