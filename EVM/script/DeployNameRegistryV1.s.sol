// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {NameRegistryV1} from "../src/NameRegistryV1.sol";

// Usage (example):
// PRIVATE_KEY=0x... TREASURY=0x... REG_FEE_WEI=10000000000000000 REFERRER_BPS=300 \
// forge script script/DeployNameRegistryV1.s.sol:DeployNameRegistryV1 \
//   --rpc-url $RPC_URL --broadcast -vv
contract DeployNameRegistryV1 is Script {
    function run() external returns (NameRegistryV1 reg) {
        // Required env vars
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY");
        uint256 registrationFeeWei = vm.envUint("REG_FEE_WEI");
        uint256 refBpsU = vm.envUint("REFERRER_BPS");
        require(refBpsU <= type(uint16).max, "ref bps too large");
        uint16 referrerBps = uint16(refBpsU);

        vm.startBroadcast(deployerKey);
        reg = new NameRegistryV1(treasury, registrationFeeWei, referrerBps);
        vm.stopBroadcast();

        console2.log("NameRegistryV1 deployed:", address(reg));
        console2.log("Treasury:", treasury);
        console2.log("Registration fee (wei):", registrationFeeWei);
        console2.log("Referrer BPS:", uint256(referrerBps));
    }
}
