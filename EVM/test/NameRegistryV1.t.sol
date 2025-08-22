// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {NameRegistryV1} from "../src/NameRegistryV1.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "M";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool){
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
    function approve(address sp, uint256 amt) external returns (bool){ allowance[msg.sender][sp] = amt; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool){
        require(balanceOf[f] >= a && allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

contract BadReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address sp, uint256 amt) external returns (bool){ allowance[msg.sender][sp] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool){
        // return false even if moved
        if (balanceOf[msg.sender] >= amt) { balanceOf[msg.sender]-=amt; balanceOf[to]+=amt; }
        return false;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool){
        if (allowance[f][msg.sender] >= a && balanceOf[f] >= a) { allowance[f][msg.sender]-=a; balanceOf[f]-=a; balanceOf[t]+=a; }
        return false;
    }
}

contract FeeOnTransferERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps = 500; // 5%
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address sp, uint256 amt) external returns (bool){ allowance[msg.sender][sp] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool){
        require(balanceOf[msg.sender] >= amt, "bal");
        uint256 fee = amt * feeBps / 10_000; uint256 out = amt - fee;
        balanceOf[msg.sender] -= amt; balanceOf[to] += out; // fee burned
        return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool){
        require(allowance[f][msg.sender] >= a && balanceOf[f] >= a, "allow");
        allowance[f][msg.sender] -= a; balanceOf[f] -= a;
        uint256 fee = a * feeBps / 10_000; uint256 out = a - fee;
        balanceOf[t] += out; // fee burned
        return true;
    }
}

contract ReentrantToken {
    NameRegistryV1 reg;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(NameRegistryV1 r) { reg = r; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address sp, uint256 amt) external returns (bool){ allowance[msg.sender][sp] = amt; return true; }
    function transfer(address, uint256) external pure returns (bool){ return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool){
        require(allowance[f][msg.sender] >= a && balanceOf[f] >= a, "allow");
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a;
        // attempt reentrancy into register
        try reg.register("reenter") { revert("should-nonReenter"); } catch {}
        return true;
    }
}

contract MaliciousReceiver {
    bool public shouldRevert;
    constructor(bool r){ shouldRevert = r; }
    receive() external payable {
        if (shouldRevert) revert("nope");
    }
}

contract NameRegistryV1Test is Test {
    NameRegistryV1 reg;
    address treasury = address(0xA11CE);
    address alice = address(0xA);
    address relayer;
    MockERC20 usdc;
    BadReturnERC20 bad;
    FeeOnTransferERC20 fot;

    function setUp() public {
    reg = new NameRegistryV1(treasury, 0.01 ether, 300); // 3% ref share
    usdc = new MockERC20();
    bad = new BadReturnERC20();
    fot = new FeeOnTransferERC20();
        reg.setERC20Fee(address(usdc), 50e6, true);
        vm.deal(alice, 1 ether);
    relayer = vm.addr(2);
    vm.deal(relayer, 1 ether);
    }

    function testRegisterETH() public {
        vm.prank(alice);
        reg.register{value: 0.01 ether}("alice");
        (address owner,,) = reg.record("alice");
        assertEq(owner, alice);
    }

    function testRegisterERC20() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(reg), type(uint256).max);
        reg.registerERC20("alice2", address(usdc));
        vm.stopPrank();
        (address owner,,) = reg.record("alice2");
        assertEq(owner, alice);
    }

    function testInvalidNamesRevert() public {
        string[8] memory badNames = ["AlIce", "a", "ab", string(abi.encodePacked(bytes32(""))), "--bad", "bad-", "ba_d", "sp ce"];
        // Adjust some specifically
        badNames[2] = "ab"; // too short
        badNames[3] = string(abi.encodePacked(bytes32(0))); // 32 zero bytes -> invalid chars
        for (uint i; i < badNames.length; i++) {
            vm.expectRevert();
            reg.register(badNames[i]);
        }
    }

    function testDuplicateRegistrationReverts() public {
        vm.prank(alice); reg.register{value: 0.01 ether}("dup");
        vm.expectRevert(); reg.register{value: 0.01 ether}("dup");
    }

    function testExactEthRequired() public {
        vm.expectRevert(); reg.register{value: 0}("pay");
        vm.expectRevert(); reg.register{value: 0.02 ether}("pay");
    }

    function testSetResolvedOnlyOwner() public {
        vm.prank(alice); reg.register{value: 0.01 ether}("own");
        vm.expectRevert(); reg.setResolved("own", address(0x1));
        vm.prank(alice); vm.expectRevert(); reg.setResolved("own", address(0));
        vm.prank(alice); reg.setResolved("own", address(0xBEEF));
        (,address res,) = reg.record("own");
        assertEq(res, address(0xBEEF));
    }

    function testTransferNameOnlyOwner() public {
        vm.prank(alice); reg.register{value: 0.01 ether}("move");
        vm.expectRevert(); reg.transferName("move", address(0x1));
        vm.prank(alice); vm.expectRevert(); reg.transferName("move", address(0));
        vm.prank(alice); reg.transferName("move", address(0xCAFE));
        (address newOwner,,) = reg.record("move");
        assertEq(newOwner, address(0xCAFE));
    }

    function testAdminOnly() public {
        vm.prank(alice); vm.expectRevert(); reg.setRegistrationFee(1);
        vm.prank(alice); vm.expectRevert(); reg.setERC20Fee(address(usdc), 1, true);
        vm.prank(alice); vm.expectRevert(); reg.setTreasury(address(1));
        vm.prank(alice); vm.expectRevert(); reg.setReferrerBps(1);
    }

    function testAdminBounds() public {
        vm.prank(address(this)); reg.setRegistrationFee(123);
        vm.prank(address(this)); reg.setERC20Fee(address(usdc), 60e6, true);
        vm.expectRevert(); vm.prank(address(this)); reg.setTreasury(address(0));
        vm.expectRevert(); vm.prank(address(this)); reg.setReferrerBps(10001);
    }

    function testOwnershipTransfer() public {
        address newAdmin = address(0xDAD);
        reg.transferOwnership(newAdmin);
        vm.prank(newAdmin); reg.acceptOwnership();
        // now only new admin can set fee
        vm.startPrank(newAdmin);
        reg.setRegistrationFee(42);
        vm.stopPrank();
    }

    function testRegisterWithSig_ReplayNonce() public {
        address owner_ = vm.addr(3);
        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _signRegister("zzz", owner_, relayer, address(0), 0, deadline, 0, 3);
        vm.prank(relayer); reg.registerWithSig{value: 0.01 ether}(NameRegistryV1.RegisterWithSigParams({
            name:"zzz", owner:owner_, relayer:relayer, currency:address(0), amount:0, deadline:deadline, nonce:0
        }), sig);
        // replay should fail as nonce increased
        vm.expectRevert();
        vm.prank(relayer); reg.registerWithSig{value: 0.01 ether}(NameRegistryV1.RegisterWithSigParams({
            name:"zzz", owner:owner_, relayer:relayer, currency:address(0), amount:0, deadline:deadline, nonce:0
        }), sig);
    }

    function testRegisterWithSig_WrongRelayer() public {
        address owner_ = vm.addr(4);
        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _signRegister("aa", owner_, relayer, address(0), 0, deadline, 0, 4);
        vm.expectRevert();
        reg.registerWithSig{value: 0.01 ether}(NameRegistryV1.RegisterWithSigParams({
            name:"aa", owner:owner_, relayer:relayer, currency:address(0), amount:0, deadline:deadline, nonce:0
        }), sig);
    }

    function testRegisterWithSig_Expired() public {
        address owner_ = vm.addr(5);
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signRegister("bb", owner_, relayer, address(0), 0, deadline, 0, 5);
        vm.prank(relayer);
        vm.expectRevert();
        reg.registerWithSig{value: 0.01 ether}(NameRegistryV1.RegisterWithSigParams({
            name:"bb", owner:owner_, relayer:relayer, currency:address(0), amount:0, deadline:deadline, nonce:0
        }), sig);
    }

    function testRegisterWithSig_TokenWrongAmount() public {
        address owner_ = vm.addr(6);
        usdc.mint(relayer, 100e6);
        vm.startPrank(relayer); usdc.approve(address(reg), type(uint256).max);
        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _signRegister("cc", owner_, relayer, address(usdc), 40e6, deadline, 0, 6);
        vm.expectRevert();
        reg.registerWithSig(NameRegistryV1.RegisterWithSigParams({
            name:"cc", owner:owner_, relayer:relayer, currency:address(usdc), amount:40e6, deadline:deadline, nonce:0
        }), sig);
        vm.stopPrank();
    }

    function testERC20FalseReturnReverts() public {
        reg.setERC20Fee(address(bad), 1e6, true);
        bad.mint(alice, 2e6);
        vm.startPrank(alice); bad.approve(address(reg), type(uint256).max);
        vm.expectRevert(); reg.registerERC20("f", address(bad));
        vm.stopPrank();
    }

    function testFeeOnTransferBreaksSplit() public {
        reg.setERC20Fee(address(fot), 100e6, true);
        fot.mint(alice, 200e6);
        vm.startPrank(alice); fot.approve(address(reg), type(uint256).max);
        // transferFrom delivers less than expected -> later transfer to treasury should revert
        vm.expectRevert(); reg.registerERC20("fot", address(fot));
        vm.stopPrank();
    }

    function testReentrancyBlocked_ViaERC20TransferFrom() public {
        ReentrantToken rt = new ReentrantToken(reg);
        reg.setERC20Fee(address(rt), 10, true);
        rt.mint(alice, 100);
        vm.startPrank(alice); rt.approve(address(reg), type(uint256).max);
    reg.registerERC20("reenter2", address(rt));
    vm.stopPrank();
    (address owner1,,) = reg.record("reenter2");
    assertEq(owner1, alice);
    (address owner2,,) = reg.record("reenter");
    assertEq(owner2, address(0));
    }

    function testMaliciousTreasuryBreaksRegistration() public {
        // deploy registry with malicious treasury that reverts on receive
        MaliciousReceiver badTreasury = new MaliciousReceiver(true);
        NameRegistryV1 reg2 = new NameRegistryV1(address(badTreasury), 0.01 ether, 300);
        vm.deal(alice, 1 ether);
        vm.prank(alice); vm.expectRevert(); reg2.register{value: 0.01 ether}("evil");
    }

    function testReferrerRevertBreaksRegisterWithSig() public {
        // set relayer to a reverting receiver
        MaliciousReceiver badRef = new MaliciousReceiver(true);
        address owner_ = vm.addr(7);
        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _signRegister("rf", owner_, address(badRef), address(0), 0, deadline, 0, 7);
        vm.deal(address(badRef), 0.1 ether);
        vm.prank(address(badRef));
        vm.expectRevert();
        // send exact fee; split to referrer will revert
        reg.registerWithSig{value: 0.01 ether}(NameRegistryV1.RegisterWithSigParams({
            name:"rf", owner:owner_, relayer:address(badRef), currency:address(0), amount:0, deadline:deadline, nonce:0
        }), sig);
    }

    function _signRegister(string memory name_, address owner_, address relayer_, address currency_, uint256 amount_, uint256 deadline_, uint256 nonce_, uint256 pk) internal view returns (bytes memory) {
        bytes32 domainSep = reg.domainSeparator();
        bytes32 typehash = keccak256("Register(string name,address owner,address relayer,address currency,uint256 amount,uint256 deadline,uint256 nonce)");
        bytes32 nameHash = keccak256(bytes(name_));
        bytes32 structHash = keccak256(abi.encode(typehash, nameHash, owner_, relayer_, currency_, amount_, deadline_, nonce_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function testRegisterWithSigETH() public {
        address owner_ = vm.addr(1);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 120;
        bytes memory sig = _signRegister("bob", owner_, relayer, address(0), 0, deadline, nonce, 1);
        vm.prank(relayer);
        reg.registerWithSig{value: 0.01 ether}(NameRegistryV1.RegisterWithSigParams({
            name: "bob",
            owner: owner_,
            relayer: relayer,
            currency: address(0),
            amount: 0,
            deadline: deadline,
            nonce: nonce
        }), sig);
        (address owner,,) = reg.record("bob");
        assertEq(owner, owner_);
    }

    function testRegisterWithSigERC20() public {
        address owner_ = vm.addr(1);
        // fund relayer in usdc
        usdc.mint(relayer, 100e6);
        vm.startPrank(relayer);
        usdc.approve(address(reg), type(uint256).max);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 120;
        bytes memory sig = _signRegister("carol", owner_, relayer, address(usdc), 50e6, deadline, nonce, 1);
        reg.registerWithSig(NameRegistryV1.RegisterWithSigParams({
            name: "carol",
            owner: owner_,
            relayer: relayer,
            currency: address(usdc),
            amount: 50e6,
            deadline: deadline,
            nonce: nonce
        }), sig);
        vm.stopPrank();
        (address owner,,) = reg.record("carol");
        assertEq(owner, owner_);
    }

    function testRelayerAllowlistEnforcedETH() public {
        address owner_ = vm.addr(8);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 120;
        bytes memory sig = _signRegister("allow", owner_, relayer, address(0), 0, deadline, nonce, 8);
        // enable gating without adding relayer -> should revert
    vm.expectEmit(true, true, true, true);
    emit NameRegistryV1.RequireRelayerAllowlistSet(true);
    vm.prank(address(this)); reg.setRequireRelayerAllowlist(true);
        vm.prank(relayer);
        vm.expectRevert(bytes("NR:relayer!allowed"));
        reg.registerWithSig{value: 0.01 ether}(NameRegistryV1.RegisterWithSigParams({
            name: "allow",
            owner: owner_,
            relayer: relayer,
            currency: address(0),
            amount: 0,
            deadline: deadline,
            nonce: nonce
        }), sig);
        // allow the relayer, then it should pass
    vm.expectEmit(true, true, true, true);
    emit NameRegistryV1.RelayerSet(relayer, true);
    vm.prank(address(this)); reg.setRelayer(relayer, true);
        vm.prank(relayer);
        reg.registerWithSig{value: 0.01 ether}(NameRegistryV1.RegisterWithSigParams({
            name: "allow",
            owner: owner_,
            relayer: relayer,
            currency: address(0),
            amount: 0,
            deadline: deadline,
            nonce: nonce
        }), sig);
        (address o,,) = reg.record("allow");
        assertEq(o, owner_);
    }

    function testRelayerAllowlistEnforcedERC20() public {
        // setup ERC20
        usdc.mint(relayer, 100e6);
        vm.startPrank(relayer); usdc.approve(address(reg), type(uint256).max); vm.stopPrank();
        address owner_ = vm.addr(9);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 120;
        bytes memory sig = _signRegister("allow2", owner_, relayer, address(usdc), 50e6, deadline, nonce, 9);
        // enable gating without allowlisting relayer
    vm.expectEmit(true, true, true, true);
    emit NameRegistryV1.RequireRelayerAllowlistSet(true);
    vm.prank(address(this)); reg.setRequireRelayerAllowlist(true);
        vm.prank(relayer);
        vm.expectRevert(bytes("NR:relayer!allowed"));
        reg.registerWithSig(NameRegistryV1.RegisterWithSigParams({
            name: "allow2",
            owner: owner_,
            relayer: relayer,
            currency: address(usdc),
            amount: 50e6,
            deadline: deadline,
            nonce: nonce
        }), sig);
        // now add relayer and succeed
    vm.expectEmit(true, true, true, true);
    emit NameRegistryV1.RelayerSet(relayer, true);
    vm.prank(address(this)); reg.setRelayer(relayer, true);
        vm.prank(relayer);
        reg.registerWithSig(NameRegistryV1.RegisterWithSigParams({
            name: "allow2",
            owner: owner_,
            relayer: relayer,
            currency: address(usdc),
            amount: 50e6,
            deadline: deadline,
            nonce: nonce
        }), sig);
        (address o,,) = reg.record("allow2");
        assertEq(o, owner_);
    }
}
