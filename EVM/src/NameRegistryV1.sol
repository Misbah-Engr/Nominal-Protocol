// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Nominal Name Registry V1 (EVM)
/// @notice Minimal, security-first name registry using on-chain string keys.
/// Features: pay-once (ETH or allowlisted ERC20), referrer payout (registerWithSig only),
/// per-name nonces for EIP-712, relayer-binding, strict name validation.
contract NameRegistryV1 {
    // --- Types ---
    struct Record {
        address owner;
        address resolved;
        uint64 updatedAt;
    }

    struct ERC20FeeInfo {
        uint256 amount;
        bool enabled;
    }

    struct RegisterWithSigParams {
        string name;
        address owner;
        address relayer; // must equal msg.sender
        address currency; // address(0) for ETH, else ERC20
        uint256 amount; // required for ERC20
        uint256 deadline;
        uint256 nonce; // per-name
    }

    // --- Events ---
    event Registered(string indexed name, address indexed owner);
    event ResolvedUpdated(string indexed name, address indexed resolved);
    event OwnershipTransferred(string indexed name, address indexed oldOwner, address indexed newOwner);
    event FeePaid(string indexed name, address indexed payer, address currency, uint256 amount, address referrer);
    event ERC20FeeSet(address token, uint256 amount, bool enabled);
    event RegistrationFeeSet(uint256 amountWei);
    event TreasurySet(address treasury);
    event ReferrerBpsSet(uint16 bps);
    event RelayerSet(address indexed relayer, bool allowed);
    event RequireRelayerAllowlistSet(bool enabled);
    event OwnershipAdminTransferInitiated(address indexed newOwner);
    event OwnershipAdminAccepted(address indexed newOwner);
    event PrimaryNameSet(address indexed owner, string indexed name);

    // --- Storage ---
    mapping(string => Record) private records;
    mapping(string => uint256) public nonces; // per-name
    mapping(address => string) private primaryNames; // address to primary name

    // fees
    uint256 public registrationFee; // ETH price (wei)
    mapping(address => ERC20FeeInfo) public erc20Fees; // token => fee info
    address public treasury;
    uint16 public referrerBps; // out of 10_000
    // relayer allowlist
    mapping(address => bool) public isRelayer;
    bool public requireRelayerAllowlist;

    // admin
    address public owner;
    address public pendingOwner;

    // reentrancy guard
    uint256 private _locked;

    // EIP-712
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant REGISTER_TYPEHASH = keccak256(
        "Register(string name,address owner,address relayer,address currency,uint256 amount,uint256 deadline,uint256 nonce)"
    );
    bytes32 private immutable _DOMAIN_SEPARATOR;
    bytes32 private constant _NAME_HASH = keccak256(bytes("NominalNameRegistryV1"));
    bytes32 private constant _VERSION_HASH = keccak256(bytes("1"));

    // --- Modifiers ---
    modifier onlyAdmin() {
        require(msg.sender == owner, "NR:!admin");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 0, "NR:reentrancy");
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor(address _treasury, uint256 _registrationFeeWei, uint16 _referrerBps) {
        require(_treasury != address(0), "NR:treasury");
        require(_referrerBps <= 10_000, "NR:bps");
        owner = msg.sender;
        treasury = _treasury;
        registrationFee = _registrationFeeWei;
        referrerBps = _referrerBps;
        requireRelayerAllowlist = false;
        _DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    // --- Views ---
    function record(string calldata name) external view returns (address, address, uint64) {
        Record storage r = records[name];
        return (r.owner, r.resolved, r.updatedAt);
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Get the primary name associated with an address
     * @param addr The address to look up
     * @return The primary name for the address, or empty string if not set
     */
    function nameOf(address addr) external view returns (string memory) {
        return primaryNames[addr];
    }

    // --- Public: register (ETH) ---
    function register(string calldata name) external payable nonReentrant {
        require(_isValidName(name), "NR:name");
        require(records[name].owner == address(0), "NR:taken");
        require(msg.value == registrationFee, "NR:fee");

        // effects
        records[name] = Record({owner: msg.sender, resolved: msg.sender, updatedAt: uint64(block.timestamp)});
        
        // Set as primary name if the user doesn't have one yet
        if (bytes(primaryNames[msg.sender]).length == 0) {
            primaryNames[msg.sender] = name;
            emit PrimaryNameSet(msg.sender, name);
        }

        emit Registered(name, msg.sender);
        emit FeePaid(name, msg.sender, address(0), msg.value, address(0));

        // interactions
        _safeTransferETH(treasury, msg.value);
    }

    // --- Public: register (ERC20) ---
    function registerERC20(string calldata name, address token) external nonReentrant {
        require(_isValidName(name), "NR:name");
        require(records[name].owner == address(0), "NR:taken");
        ERC20FeeInfo memory info = erc20Fees[token];
        require(info.enabled, "NR:token");

        // pull tokens first (checks happen inside)
        _safeTransferFromERC20(token, msg.sender, address(this), info.amount);

        // effects
        records[name] = Record({owner: msg.sender, resolved: msg.sender, updatedAt: uint64(block.timestamp)});
        
        // Set as primary name if the user doesn't have one yet
        if (bytes(primaryNames[msg.sender]).length == 0) {
            primaryNames[msg.sender] = name;
            emit PrimaryNameSet(msg.sender, name);
        }

        emit Registered(name, msg.sender);
        emit FeePaid(name, msg.sender, token, info.amount, address(0));

        // interactions: send to treasury
        _safeTransferERC20(token, treasury, info.amount);
    }

    // --- Meta: register with signature ---
    function registerWithSig(RegisterWithSigParams calldata p, bytes calldata sig) external payable nonReentrant {
        require(block.timestamp <= p.deadline, "NR:deadline");
        require(msg.sender == p.relayer, "NR:relayer");
        if (requireRelayerAllowlist) {
            require(isRelayer[p.relayer], "NR:relayer!allowed");
        }
        require(_isValidName(p.name), "NR:name");
        require(records[p.name].owner == address(0), "NR:taken");
        require(p.owner != address(0), "NR:owner");

        // nonce check
        require(p.nonce == nonces[p.name], "NR:nonce");

        // verify signature (owner signed)
        bytes32 structHash = keccak256(
            abi.encode(
                REGISTER_TYPEHASH,
                keccak256(bytes(p.name)),
                p.owner,
                p.relayer,
                p.currency,
                p.amount,
                p.deadline,
                p.nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
        address recovered = _recover(digest, sig);
        require(recovered == p.owner, "NR:sig");

        // consume nonce
        unchecked { nonces[p.name] = p.nonce + 1; }

        // payments
        if (p.currency == address(0)) {
            require(msg.value == registrationFee, "NR:fee");
            // effects
            records[p.name] = Record({owner: p.owner, resolved: p.owner, updatedAt: uint64(block.timestamp)});
            
            // Set as primary name if the user doesn't have one yet
            if (bytes(primaryNames[p.owner]).length == 0) {
                primaryNames[p.owner] = p.name;
                emit PrimaryNameSet(p.owner, p.name);
            }

            emit Registered(p.name, p.owner);

            // split
            uint256 refShare = (msg.value * referrerBps) / 10_000;
            uint256 treas = msg.value - refShare;
            emit FeePaid(p.name, msg.sender, address(0), msg.value, msg.sender);
            _safeTransferETH(treasury, treas);
            if (refShare > 0) _safeTransferETH(msg.sender, refShare);
        } else {
            ERC20FeeInfo memory info = erc20Fees[p.currency];
            require(info.enabled, "NR:token");
            require(p.amount == info.amount, "NR:amt");

            // pull first
            _safeTransferFromERC20(p.currency, msg.sender, address(this), p.amount);

            // effects
            records[p.name] = Record({owner: p.owner, resolved: p.owner, updatedAt: uint64(block.timestamp)});
            
            // Set as primary name if the user doesn't have one yet
            if (bytes(primaryNames[p.owner]).length == 0) {
                primaryNames[p.owner] = p.name;
                emit PrimaryNameSet(p.owner, p.name);
            }

            emit Registered(p.name, p.owner);

            // split
            uint256 refShare = (p.amount * referrerBps) / 10_000;
            uint256 treas = p.amount - refShare;
            emit FeePaid(p.name, msg.sender, p.currency, p.amount, msg.sender);
            if (treas > 0) _safeTransferERC20(p.currency, treasury, treas);
            if (refShare > 0) _safeTransferERC20(p.currency, msg.sender, refShare);
        }
    }

    // --- Mutations: owner-controlled name ops ---
    function setResolved(string calldata name, address newResolved) external {
        require(_isValidName(name), "NR:name");
        Record storage r = records[name];
        require(r.owner == msg.sender, "NR:!owner");
        require(newResolved != address(0), "NR:zero");
        r.resolved = newResolved;
        r.updatedAt = uint64(block.timestamp);
        emit ResolvedUpdated(name, newResolved);
    }

    function transferName(string calldata name, address newOwner) external {
        Record storage r = records[name];
        require(r.owner == msg.sender, "NR:!owner");
        require(newOwner != address(0), "NR:zero");
        address old = r.owner;
        r.owner = newOwner;
        r.updatedAt = uint64(block.timestamp);
        
        // If this was the primary name for the old owner, clear it
        string storage primaryName = primaryNames[old];
        if (bytes(primaryName).length > 0 && keccak256(bytes(primaryName)) == keccak256(bytes(name))) {
            delete primaryNames[old];
        }
        
        // If the new owner doesn't have a primary name, set this as their primary
        if (bytes(primaryNames[newOwner]).length == 0) {
            primaryNames[newOwner] = name;
            emit PrimaryNameSet(newOwner, name);
        }
        
        emit OwnershipTransferred(name, old, newOwner);
    }
    
    /**
     * @notice Set a name as primary for the sender's address
     * @param name The name to set as primary
     */
    function setPrimaryName(string calldata name) external {
        require(_isValidName(name), "NR:name");
        Record storage r = records[name];
        require(r.owner == msg.sender, "NR:!owner");
        require(r.owner != address(0), "NR:!exist"); // Ensure the name exists in the registry
        primaryNames[msg.sender] = name;
        emit PrimaryNameSet(msg.sender, name);
    }

    // --- Admin ---
    function setRegistrationFee(uint256 amountWei) external onlyAdmin {
        registrationFee = amountWei;
        emit RegistrationFeeSet(amountWei);
    }

    function setERC20Fee(address token, uint256 amount, bool enabled) external onlyAdmin {
        require(token != address(0), "NR:token0");
        erc20Fees[token] = ERC20FeeInfo({amount: amount, enabled: enabled});
        emit ERC20FeeSet(token, amount, enabled);
    }

    function setTreasury(address _treasury) external onlyAdmin {
        require(_treasury != address(0), "NR:treasury");
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function setReferrerBps(uint16 bps) external onlyAdmin {
        require(bps <= 10_000, "NR:bps");
        referrerBps = bps;
        emit ReferrerBpsSet(bps);
    }

    function setRelayer(address relayer, bool allowed) external onlyAdmin {
        require(relayer != address(0), "NR:zero");
        isRelayer[relayer] = allowed;
        emit RelayerSet(relayer, allowed);
    }

    function setRequireRelayerAllowlist(bool enabled) external onlyAdmin {
        requireRelayerAllowlist = enabled;
        emit RequireRelayerAllowlistSet(enabled);
    }

    function transferOwnership(address newOwner) external onlyAdmin {
        require(newOwner != address(0), "NR:zero");
        pendingOwner = newOwner;
        emit OwnershipAdminTransferInitiated(newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NR:!pending");
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipAdminAccepted(owner);
    }

    // --- Internal: helpers ---
    function _isValidName(string memory name) internal pure returns (bool) {
        bytes memory b = bytes(name);
        uint256 len = b.length;
        if (len < 3 || len > 32) return false;
        if (b[0] == 0x2D || b[len - 1] == 0x2D) return false; // '-'
        for (uint256 i = 0; i < len; i++) {
            bytes1 c = b[i];
            bool ok = (c >= 0x30 && c <= 0x39) || // 0-9
                      (c >= 0x61 && c <= 0x7A) || // a-z
                      (c == 0x2D);               // '-'
            if (!ok) return false;
        }
        return true;
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "NR:eth");
    }

    function _safeTransferERC20(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "NR:erc20");
    }

    function _safeTransferFromERC20(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)")), from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "NR:erc20from");
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                _NAME_HASH,
                _VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    function _domainSeparatorV4() private view returns (bytes32) {
        return _DOMAIN_SEPARATOR;
    }

    function _recover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        require(sig.length == 65, "NR:siglen");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        // EIP-2 malleability
        require(uint256(s) <= 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff, "NR:sval");
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "NR:v");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "NR:rec");
        return signer;
    }
}
