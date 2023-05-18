require('dotenv').config();

module.exports = {

    networks: {
        development: {
            host: "127.0.0.1",
            port: 9545,
            network_id: "*"
        }
    },

    mocha: {
        timeout: 100000
    },

    compilers: {
        solc: {
            version: "0.8.12",
            settings: {
                optimizer: {
                    enabled: true,
                    runs: 200
                }
            }
        }
    },

    db: {
        enabled: false
    }

};