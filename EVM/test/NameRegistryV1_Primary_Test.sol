// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/NameRegistryV1.sol";
import "forge-std/Test.sol";

contract NameRegistryV1Test is Test {
    NameRegistryV1 registry;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address treasury = address(0x1);
    
    function setUp() public {
        registry = new NameRegistryV1(treasury, 1 ether, 1000); // 10% referrer fee
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }
    
    function testSetPrimaryName() public {
        // Alice registers a name
        vm.prank(alice);
        registry.register{value: 1 ether}("alice");
        
        // Alice registers a second name
        vm.prank(alice);
        registry.register{value: 1 ether}("alice2");
        
        // Check that primary name is the first one
        assertEq(registry.nameOf(alice), "alice");
        
        // Explicitly set the second name as primary
        vm.prank(alice);
        registry.setPrimaryName("alice2");
        
        // Check that primary name updated
        assertEq(registry.nameOf(alice), "alice2");
    }
    
    function testSetPrimaryNameRequiresValidName() public {
        // Alice registers a name
        vm.prank(alice);
        registry.register{value: 1 ether}("alice");
        
        // Try to set an invalid name as primary (too short)
        string memory invalidName = "al";
        vm.prank(alice);
        vm.expectRevert("NR:name");
        registry.setPrimaryName(invalidName);
        
        // Try with invalid characters
        invalidName = "alice!";
        vm.prank(alice);
        vm.expectRevert("NR:name");
        registry.setPrimaryName(invalidName);
    }
    
    function testTransferNameHandlesEmptyPrimaryName() public {
        // Alice registers a name
        vm.prank(alice);
        registry.register{value: 1 ether}("alice");
        
        // Manually clear Alice's primary name to test edge case
        vm.store(
            address(registry),
            keccak256(abi.encode(alice, uint256(2))), // slot for primaryNames[alice]
            bytes32(0)
        );
        
        // Now transfer the name
        vm.prank(alice);
        registry.transferName("alice", bob);
        
        // Bob should have it as primary
        assertEq(registry.nameOf(bob), "alice");
    }
    
    function testSetResolvedRequiresValidName() public {
        // Alice registers a name
        vm.prank(alice);
        registry.register{value: 1 ether}("alice");
        
        // Try to set resolved for an invalid name
        string memory invalidName = "al";
        vm.prank(alice);
        vm.expectRevert("NR:name");
        registry.setResolved(invalidName, alice);
    }
    
    function testTransferPrimaryName() public {
        // Alice registers a name
        vm.prank(alice);
        registry.register{value: 1 ether}("test");
        
        // Check that it's her primary name
        assertEq(registry.nameOf(alice), "test");
        
        // Transfer to Bob
        vm.prank(alice);
        registry.transferName("test", bob);
        
        // Alice's primary name should be cleared
        assertEq(registry.nameOf(alice), "");
        
        // Bob should have it as primary (since he had none)
        assertEq(registry.nameOf(bob), "test");
        
        // Now Bob transfers back, but Alice has no primary
        vm.prank(bob);
        registry.transferName("test", alice);
        
        // Should be set as Alice's primary again
        assertEq(registry.nameOf(alice), "test");
    }
}
