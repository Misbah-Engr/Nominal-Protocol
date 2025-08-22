// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/NameRegistryV1.sol";

contract TestPrimaryNameScript is Script {
    address constant TREASURY = address(0x1);
    uint256 constant REG_FEE = 0.01 ether;
    uint16 constant REFERRER_BPS = 1000; // 10%

    function run() external {
        // Setup test wallets
        uint256 aliceKey = 0xA11CE;
        uint256 bobKey = 0xB0B;
        address alice = vm.addr(aliceKey);
        address bob = vm.addr(bobKey);
        
        // Deploy registry
        vm.startBroadcast();
        NameRegistryV1 registry = new NameRegistryV1(TREASURY, REG_FEE, REFERRER_BPS);
        console.log("Registry deployed at:", address(registry));
        
        // Alice registers a name
        vm.deal(alice, 1 ether);
        vm.stopBroadcast();
        
        vm.startBroadcast(aliceKey);
        registry.register{value: REG_FEE}("alice");
        console.log("Alice registered 'alice'");
        console.log("Primary name of Alice:", registry.nameOf(alice));
        
        // Alice registers a second name
        registry.register{value: REG_FEE}("alice-alt");
        console.log("Alice registered 'alice-alt'");
        console.log("Primary name of Alice:", registry.nameOf(alice));
        
        // Alice sets her primary name to the second one
        registry.setPrimaryName("alice-alt");
        console.log("Alice set primary name to 'alice-alt'");
        console.log("Primary name of Alice:", registry.nameOf(alice));
        vm.stopBroadcast();
        
        // Bob registers a name
        vm.deal(bob, 1 ether);
        vm.startBroadcast(bobKey);
        registry.register{value: REG_FEE}("bob");
        console.log("Bob registered 'bob'");
        console.log("Primary name of Bob:", registry.nameOf(bob));
        vm.stopBroadcast();
        
        // Alice transfers a name to Bob
        vm.startBroadcast(aliceKey);
        registry.transferName("alice", bob);
        console.log("Alice transferred 'alice' to Bob");
        console.log("Primary name of Alice:", registry.nameOf(alice));
        console.log("Primary name of Bob:", registry.nameOf(bob));
        vm.stopBroadcast();
    }
}
