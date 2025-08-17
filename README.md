# Nominal-Protocol
Nominal Resolution Protocol is a new framework for abstracting cryptographic wallet addresses into a single, human-readable namespace across separate and non-compatible blockchain networks, including EVM, MoveVM, Solana, and NEAR execution environments.

## Features

- **Cross-chain name resolution**: Resolve human-readable names to addresses across different blockchains
- **Bidirectional resolution**: Resolve from names to addresses AND from addresses to names
- **Pay once, own forever**: No recurring fees or annual renewals
- **Wallet revenue sharing**: Integration partners can earn a percentage of registration fees
- **ERC-20 payment support**: Register names using popular stablecoins
- **Security-first design**: Non-upgradeable contracts with minimal trust assumptions

## Project Structure

- **EVM/**: Ethereum implementation
  - Solidity contracts for name registry
  - Bidirectional name resolution (name→address, address→name)
  - Test suite and deployment scripts
- **Sui/**: Move implementation for Sui blockchain

## Documentation

For detailed technical information, see:
- [EVM Architecture](EVM/ARCHITECTURE.md)
- [Primary Name System](EVM/PRIMARYNAME.md)
- [Litepaper](EVM/litepaper.txt)

## Cross-chain FT fees and referrer payouts

Overview of how fungible token fees are configured and how referrer splits work across VMs:

- EVM
  - Fees: `setRegistrationFee(wei)` for ETH; `setERC20Fee(token, amount, enabled)` per token.
  - Register (direct): ETH/ERC20 → 100% to treasury.
  - Register with signature: ETH/ERC20 → referrer split to relayer (based on `referrerBps`), remainder to treasury.
  - Relayers: Admin can `setRelayer(addr, allowed)` and toggle enforcement via `setRequireRelayerAllowlist(bool)`; when enabled, only allowlisted relayers can perform meta registrations.

- NEAR
  - Fees: `set_registration_fee(amount)` for native; `set_coin_fee(token_account_id, amount, enabled)` per NEP-141.
  - Register (native): 100% to treasury.
  - Register with signature (native): referrer split to relayer; remainder to treasury.
  - FT path via `ft_on_transfer`: takes only the required fee; optional referrer split if `relayer` provided in msg; refunds overpayment via return value; remainder to treasury.
  - Relayers: Admin can `add_relayer/remove_relayer` and `set_require_allowlisted_relayer(bool)`; enforced in meta native and FT flows when enabled.

- SUI
  - Fees: `set_registration_fee(amount)` for SUI; `set_coin_fee<T>(amount, allowed)` per coin type.
  - Register (SUI/coin): sends required fee to treasury; returns change to payer.
  - Register with signature (SUI/coin): referrer split to relayer; remainder to treasury; returns change to payer.
  - Relayers: Admin can `add_relayer/remove_relayer` and `set_require_allowlisted_relayer(bool)`; enforced in register_with_sig_sui and register_with_sig_coin.

BPS configuration
- All chains use `referrer_bps` out of 10,000 to compute the referrer share from the required fee.

Refund semantics
- EVM/NEAR native and ERC20 exact amounts are enforced in meta and direct flows (no change), except NEAR FT returns unused via `ft_on_transfer` return.
- SUI returns any overpayment (change) in both direct and meta flows.
