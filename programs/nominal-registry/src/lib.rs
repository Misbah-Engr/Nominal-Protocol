use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Mint, Transfer};
use anchor_lang::solana_program::{
    clock::Clock,
};
use anchor_lang::system_program;

declare_id!("6TVpb5Ga5c8mfgiFRddf8T1sGFJbgtzcj2WFQBB1gFMq");

// ========================================
// CONSTANTS
// ========================================
// Max name length enforced by validate_name (3-63 chars). We allocate the
// primary name account to the maximum size up-front so that subsequent
// registrations with a longer name for the same user (using init_if_needed)
// don't hit Anchor's ConstraintSpace check (which compares the declared
// space against the existing account size). Without this, a user who first
// registers a short name (allocating a small account) and later registers a
// longer name would cause a mismatch (e.g. Left: 53 Right: 50) and fail.
pub const MAX_NAME_LEN: usize = 63;
pub const PRIMARY_NAME_ACCOUNT_SPACE: usize = 8 + 37 + MAX_NAME_LEN; // discriminator + base + max name

#[allow(deprecated)]
#[program]
pub mod nominal_registry {
    use super::*;

    // ========================================
    // ADMINISTRATIVE INSTRUCTIONS
    // ========================================

    pub fn initialize(
        ctx: Context<Initialize>,
        registration_fee: u64,
        referrer_bps: u16,
    ) -> Result<()> {
        require!(referrer_bps <= 10_000, ErrorCode::InvalidReferrerBps);

        let config = &mut ctx.accounts.config;
        config.admin = ctx.accounts.admin.key();
        config.pending_admin = None;
        config.treasury = ctx.accounts.treasury.key();
        config.registration_fee = registration_fee;
        config.referrer_bps = referrer_bps;
        config.require_allowlisted_relayer = false;
        config.bump = ctx.bumps.config;

        msg!("RegistryInitialized: admin={}, treasury={}, fee={}, referrer_bps={}",
             config.admin, config.treasury, registration_fee, referrer_bps);

        Ok(())
    }

    pub fn set_registration_fee(
        ctx: Context<SetRegistrationFee>,
        new_fee: u64,
    ) -> Result<()> {
        let config = &mut ctx.accounts.config;
        config.registration_fee = new_fee;

        msg!("RegistrationFeeSet: new_fee={}", new_fee);
        Ok(())
    }

    pub fn set_token_fee(
        ctx: Context<SetTokenFee>,
        amount: u64,
        enabled: bool,
    ) -> Result<()> {
        let token_fee = &mut ctx.accounts.token_fee;
        token_fee.mint = ctx.accounts.mint.key();
        token_fee.amount = amount;
        token_fee.enabled = enabled;
        token_fee.bump = ctx.bumps.token_fee;

        msg!("TokenFeeSet: mint={}, amount={}, enabled={}",
             token_fee.mint, amount, enabled);
        Ok(())
    }

    pub fn set_treasury(
        ctx: Context<SetTreasury>,
        new_treasury: Pubkey,
    ) -> Result<()> {
        require!(new_treasury != Pubkey::default(), ErrorCode::InvalidTreasuryAddress);

        let config = &mut ctx.accounts.config;
        config.treasury = new_treasury;

        msg!("TreasurySet: new_treasury={}", new_treasury);
        Ok(())
    }

    pub fn set_referrer_bps(
        ctx: Context<SetReferrerBps>,
        bps: u16,
    ) -> Result<()> {
        require!(bps <= 10_000, ErrorCode::InvalidReferrerBps);

        let config = &mut ctx.accounts.config;
        config.referrer_bps = bps;

        msg!("ReferrerBpsSet: bps={}", bps);
        Ok(())
    }

    pub fn add_relayer(
        ctx: Context<AddRelayer>,
        relayer: Pubkey,
    ) -> Result<()> {
        let entry = &mut ctx.accounts.relayer_entry;
        entry.relayer = relayer;
        entry.bump = ctx.bumps.relayer_entry;
        msg!("RelayerAdded: relayer={}", relayer);
        Ok(())
    }

    pub fn remove_relayer(
        ctx: Context<RemoveRelayer>,
        relayer: Pubkey,
    ) -> Result<()> {
        require!(ctx.accounts.relayer_entry.relayer == relayer, ErrorCode::Unauthorized);
        msg!("RelayerRemoved: relayer={}", relayer);
        Ok(())
    }

    pub fn transfer_admin(
        ctx: Context<TransferAdmin>,
        new_admin: Pubkey,
    ) -> Result<()> {
        let config = &mut ctx.accounts.config;
        config.pending_admin = Some(new_admin);

        msg!("AdminTransferInitiated: new_admin={}", new_admin);
        Ok(())
    }

    pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
        let config = &mut ctx.accounts.config;
        let new_admin = config.pending_admin.unwrap();
        require!(ctx.accounts.new_admin.key() == new_admin, ErrorCode::Unauthorized);

        config.admin = new_admin;
        config.pending_admin = None;

        msg!("AdminTransferAccepted: new_admin={}", new_admin);
        Ok(())
    }

    // ========================================
    // USER INSTRUCTIONS
    // ========================================

    pub fn register_name(
        ctx: Context<RegisterName>,
        name: String,
    ) -> Result<()> {
        validate_name(&name)?;

        let config = &ctx.accounts.config;
        let name_record = &mut ctx.accounts.name_record;

        // Set record data
        name_record.name = name.clone();
        name_record.owner = ctx.accounts.user.key();
        name_record.resolved = ctx.accounts.user.key();
        name_record.updated_at = Clock::get()?.unix_timestamp;
        name_record.bump = ctx.bumps.name_record;

        // Transfer SOL to treasury (CPI)
        {
            let cpi_accounts = system_program::Transfer {
                from: ctx.accounts.user.to_account_info(),
                to: ctx.accounts.treasury.to_account_info(),
            };
            let cpi_ctx = CpiContext::new(ctx.accounts.system_program.to_account_info(), cpi_accounts);
            system_program::transfer(cpi_ctx, config.registration_fee)?;
        }

        // Set as primary name if user doesn't have one
        if ctx.accounts.primary_name.owner == Pubkey::default() {
            let primary = &mut ctx.accounts.primary_name;
            primary.owner = ctx.accounts.user.key();
            primary.name = name.clone();
            primary.bump = ctx.bumps.primary_name;

            msg!("PrimaryNameSet: owner={}, name={}", primary.owner, name);
        }

        msg!("NameRegistered: name={}, owner={}, resolved={}",
             name, name_record.owner, name_record.resolved);
        msg!("FeePaid: name={}, payer={}, amount={}, currency=SOL, referrer=None",
             name, ctx.accounts.user.key(), config.registration_fee);

        Ok(())
    }

    pub fn register_name_with_token(
        ctx: Context<RegisterNameWithToken>,
        name: String,
    ) -> Result<()> {
        validate_name(&name)?;

        let token_fee = &ctx.accounts.token_fee;
        require!(token_fee.enabled, ErrorCode::TokenNotEnabled);

        let name_record = &mut ctx.accounts.name_record;
        name_record.name = name.clone();
        name_record.owner = ctx.accounts.user.key();
        name_record.resolved = ctx.accounts.user.key();
        name_record.updated_at = Clock::get()?.unix_timestamp;
        name_record.bump = ctx.bumps.name_record;

        // Transfer tokens to treasury
        let cpi_accounts = Transfer {
            from: ctx.accounts.user_token_account.to_account_info(),
            to: ctx.accounts.treasury_token_account.to_account_info(),
            authority: ctx.accounts.user.to_account_info(),
        };
        let cpi_program = ctx.accounts.token_program.to_account_info();
        let cpi_ctx = CpiContext::new(cpi_program, cpi_accounts);
        token::transfer(cpi_ctx, token_fee.amount)?;

        // Set as primary name if user doesn't have one
        if ctx.accounts.primary_name.owner == Pubkey::default() {
            let primary = &mut ctx.accounts.primary_name;
            primary.owner = ctx.accounts.user.key();
            primary.name = name.clone();
            primary.bump = ctx.bumps.primary_name;

            msg!("PrimaryNameSet: owner={}, name={}", primary.owner, name);
        }

        msg!("NameRegistered: name={}, owner={}, resolved={}",
             name, name_record.owner, name_record.resolved);
        msg!("FeePaid: name={}, payer={}, amount={}, currency={}, referrer=None",
             name, ctx.accounts.user.key(), token_fee.amount, token_fee.mint);

        Ok(())
    }

    pub fn register_name_with_signature(
        ctx: Context<RegisterNameWithSignature>,
        params: RegisterWithSigParams,
        signature: Vec<u8>,
    ) -> Result<()> {
        validate_name(&params.name)?;

        // Verify deadline
        require!(Clock::get()?.unix_timestamp <= params.deadline, ErrorCode::DeadlineExpired);

        // Verify relayer
        require!(ctx.accounts.relayer.key() == params.relayer, ErrorCode::Unauthorized);

    // Enforce relayer allowlist (must have relayer_entry account present)
    let config = &ctx.accounts.config; // currently unused for gating beyond referrer bps / fee
    let relayer_entry = &ctx.accounts.relayer_entry;
    require!(relayer_entry.relayer == ctx.accounts.relayer.key(), ErrorCode::RelayerNotAllowed);

        // Verify signature (simplified - in production use proper Ed25519 verification)
        // For now, we'll trust the transaction signature mechanism
        require!(signature.len() == 64, ErrorCode::InvalidSignature);

        let name_record = &mut ctx.accounts.name_record;
        name_record.name = params.name.clone();
        name_record.owner = params.owner;
        name_record.resolved = params.owner;
        name_record.updated_at = Clock::get()?.unix_timestamp;
        name_record.bump = ctx.bumps.name_record;

        // Enforce SOL-only path here
        require!(params.currency.is_none(), ErrorCode::TokenNotEnabled);

        // SOL payment
        require!(ctx.accounts.relayer.lamports() >= config.registration_fee, ErrorCode::InsufficientTokenBalance);

        let referrer_amount = (config.registration_fee as u128)
            .checked_mul(config.referrer_bps as u128)
            .unwrap()
            .checked_div(10_000)
            .unwrap() as u64;
        let treasury_amount = config.registration_fee - referrer_amount;

        // Transfer to treasury (CPI)
        {
            let cpi_accounts = system_program::Transfer {
                from: ctx.accounts.relayer.to_account_info(),
                to: ctx.accounts.treasury.to_account_info(),
            };
            let cpi_ctx = CpiContext::new(ctx.accounts.system_program.to_account_info(), cpi_accounts);
            system_program::transfer(cpi_ctx, treasury_amount)?;
        }

        msg!("FeePaid: name={}, payer={}, amount={}, currency=SOL, referrer={}, ref_amount={}",
             params.name, ctx.accounts.relayer.key(), config.registration_fee,
             ctx.accounts.relayer.key(), referrer_amount);

        // Set as primary name if owner doesn't have one
        if ctx.accounts.primary_name.owner == Pubkey::default() {
            let primary = &mut ctx.accounts.primary_name;
            primary.owner = params.owner;
            primary.name = params.name.clone();
            primary.bump = ctx.bumps.primary_name;

            msg!("PrimaryNameSet: owner={}, name={}", params.owner, params.name);
        }

        msg!("NameRegistered: name={}, owner={}, resolved={}",
             params.name, params.owner, params.owner);

        Ok(())
    }

    // Token signature registration kept in second function below (see after SOL version)

    pub fn transfer_name(
        ctx: Context<TransferName>,
        name: String,
        new_owner: Pubkey,
    ) -> Result<()> {
        let name_record = &mut ctx.accounts.name_record;
        let old_owner = name_record.owner;

        name_record.owner = new_owner;
        name_record.updated_at = Clock::get()?.unix_timestamp;

        msg!("NameTransferred: name={}, old_owner={}, new_owner={}",
             name, old_owner, new_owner);

        Ok(())
    }

    pub fn set_resolved_address(
        ctx: Context<SetResolvedAddress>,
        name: String,
        new_resolved: Pubkey,
    ) -> Result<()> {
        let name_record = &mut ctx.accounts.name_record;
        name_record.resolved = new_resolved;
        name_record.updated_at = Clock::get()?.unix_timestamp;

        msg!("ResolvedUpdated: name={}, owner={}, new_resolved={}",
             name, name_record.owner, new_resolved);

        Ok(())
    }

    pub fn set_primary_name(
        ctx: Context<SetPrimaryName>,
        name: String,
    ) -> Result<()> {
        // Verify user owns the name
        let name_record = &ctx.accounts.name_record;
        require!(name_record.owner == ctx.accounts.user.key(), ErrorCode::Unauthorized);

        let primary = &mut ctx.accounts.primary_name;
        primary.owner = ctx.accounts.user.key();
        primary.name = name.clone();
        primary.bump = ctx.bumps.primary_name;

        msg!("PrimaryNameSet: owner={}, name={}", primary.owner, name);

        Ok(())
    }

    pub fn register_name_with_signature_token(
        ctx: Context<RegisterNameWithSignatureToken>,
        params: RegisterWithSigParams,
        signature: Vec<u8>,
    ) -> Result<()> {
        validate_name(&params.name)?;
        require!(signature.len() == 64, ErrorCode::InvalidSignature);
        let config = &ctx.accounts.config;
        // Enforce relayer allowlist
        require!(ctx.accounts.relayer_entry.relayer == ctx.accounts.relayer.key(), ErrorCode::RelayerNotAllowed);
        let token_fee = &ctx.accounts.token_fee;
        require!(token_fee.enabled, ErrorCode::TokenNotEnabled);
        require!(token_fee.amount == params.amount, ErrorCode::TokenFeeMismatch);

        // Populate name record
        let name_record = &mut ctx.accounts.name_record;
        name_record.name = params.name.clone();
        name_record.owner = params.owner;
        name_record.resolved = params.owner;
        name_record.updated_at = Clock::get()?.unix_timestamp;
        name_record.bump = ctx.bumps.name_record;

        // Compute referrer split (referrer remains relayer for now)
        let referrer_amount = (token_fee.amount as u128)
            .checked_mul(config.referrer_bps as u128)
            .unwrap()
            .checked_div(10_000)
            .unwrap() as u64;
        let treasury_amount = token_fee.amount - referrer_amount;

        // Transfer tokens to treasury
        let cpi_accounts = anchor_spl::token::Transfer {
            from: ctx.accounts.relayer_token_account.to_account_info(),
            to: ctx.accounts.treasury_token_account.to_account_info(),
            authority: ctx.accounts.relayer.to_account_info(),
        };
        let cpi_ctx = CpiContext::new(ctx.accounts.token_program.to_account_info(), cpi_accounts);
        token::transfer(cpi_ctx, treasury_amount)?;

        // Set primary name if empty
        if ctx.accounts.primary_name.owner == Pubkey::default() {
            let primary = &mut ctx.accounts.primary_name;
            primary.owner = params.owner;
            primary.name = params.name.clone();
            primary.bump = ctx.bumps.primary_name;
            msg!("PrimaryNameSet: owner={}, name={}", params.owner, params.name);
        }

        msg!("NameRegistered: name={}, owner={}, resolved={}", params.name, params.owner, params.owner);
        msg!("FeePaid: name={}, payer={}, amount={}, currency={}, referrer={}, ref_amount={}",
             params.name, ctx.accounts.relayer.key(), token_fee.amount, ctx.accounts.mint.key(),
             ctx.accounts.relayer.key(), referrer_amount);
        Ok(())
    }
}

// ========================================
// DATA STRUCTURES
// ========================================

#[account]
pub struct RegistryConfig {
    pub admin: Pubkey,                    // 32
    pub pending_admin: Option<Pubkey>,    // 33
    pub treasury: Pubkey,                 // 32
    pub registration_fee: u64,            // 8
    pub referrer_bps: u16,                // 2
    pub require_allowlisted_relayer: bool, // 1
    pub bump: u8,                         // 1
    // Total: ~109 bytes + discriminator
}

#[account]
pub struct NameRecord {
    pub name: String,         // 4 + len (up to 63)
    pub owner: Pubkey,        // 32
    pub resolved: Pubkey,     // 32
    pub updated_at: i64,      // 8
    pub bump: u8,             // 1
    // Total: ~80 bytes + name length + discriminator
}

#[account]
pub struct TokenFeeConfig {
    pub mint: Pubkey,         // 32
    pub amount: u64,          // 8
    pub enabled: bool,        // 1
    pub bump: u8,             // 1
    // Total: ~50 bytes + discriminator
}

#[account]
pub struct PrimaryNameRegistry {
    pub owner: Pubkey,        // 32
    pub name: String,         // 4 + len
    pub bump: u8,             // 1
    // Total: 37 bytes + name length; with 8-byte discriminator allocate 8 + 37 + name.len()
}

#[account]
pub struct RelayerEntry {
    pub relayer: Pubkey, // 32
    pub bump: u8,        // 1
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct RegisterWithSigParams {
    pub name: String,
    pub owner: Pubkey,
    pub relayer: Pubkey,
    pub currency: Option<Pubkey>, // None = SOL, Some = token mint
    pub amount: u64,
    pub deadline: i64,
    pub nonce: u64,
}

// ========================================
// INSTRUCTION CONTEXTS
// ========================================

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    
    /// CHECK: Treasury can be any account
    pub treasury: UncheckedAccount<'info>,
    
    #[account(
        init,
        payer = admin,
        space = 8 + 109,
        seeds = [b"config"],
        bump
    )]
    pub config: Account<'info, RegistryConfig>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SetRegistrationFee<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    
    #[account(
        mut,
        constraint = config.admin == admin.key() @ ErrorCode::Unauthorized,
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,
}

#[derive(Accounts)]
pub struct SetTokenFee<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    
    #[account(
        constraint = config.admin == admin.key() @ ErrorCode::Unauthorized,
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,
    
    pub mint: Account<'info, Mint>,
    
    #[account(
        init_if_needed,
        payer = admin,
        space = 8 + 50,
        seeds = [b"token_fee", mint.key().as_ref()],
        bump
    )]
    pub token_fee: Account<'info, TokenFeeConfig>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SetTreasury<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    
    #[account(
        mut,
        constraint = config.admin == admin.key() @ ErrorCode::Unauthorized,
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,
}

#[derive(Accounts)]
pub struct SetReferrerBps<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    
    #[account(
        mut,
        constraint = config.admin == admin.key() @ ErrorCode::Unauthorized,
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,
}

#[derive(Accounts)]
pub struct TransferAdmin<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    
    #[account(
        mut,
        constraint = config.admin == admin.key() @ ErrorCode::Unauthorized,
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,
}

#[derive(Accounts)]
pub struct AcceptAdmin<'info> {
    #[account(mut)]
    pub new_admin: Signer<'info>,
    
    #[account(
        mut,
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,
}

#[derive(Accounts)]
#[instruction(name: String)]
pub struct RegisterName<'info> {
    #[account(mut)]
    pub user: Signer<'info>,
    
    #[account(
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,
    
    #[account(
        init,
        payer = user,
        space = 8 + 77 + name.len(),
        seeds = [b"name", name.as_bytes()],
        bump
    )]
    pub name_record: Account<'info, NameRecord>,
    
    #[account(
        init_if_needed,
        payer = user,
    // Allocate max to allow future longer primary names without resize
    space = PRIMARY_NAME_ACCOUNT_SPACE,
        seeds = [b"primary", user.key().as_ref()],
        bump
    )]
    pub primary_name: Account<'info, PrimaryNameRegistry>,    /// CHECK: Treasury can be any account to receive SOL fees
    #[account(mut)]
    pub treasury: UncheckedAccount<'info>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(name: String)]
pub struct RegisterNameWithToken<'info> {
    #[account(mut)]
    pub user: Signer<'info>,
    
    #[account(
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,
    
    pub mint: Account<'info, Mint>,
    
    #[account(
        constraint = token_fee.mint == mint.key() @ ErrorCode::TokenNotEnabled,
        seeds = [b"token_fee", mint.key().as_ref()],
        bump = token_fee.bump
    )]
    pub token_fee: Account<'info, TokenFeeConfig>,
    
    #[account(
        init,
        payer = user,
        space = 8 + 77 + name.len(),
        seeds = [b"name", name.as_bytes()],
        bump
    )]
    pub name_record: Account<'info, NameRecord>,
    
    #[account(
        init_if_needed,
        payer = user,
    // Allocate max to allow future longer primary names without resize
    space = PRIMARY_NAME_ACCOUNT_SPACE,
        seeds = [b"primary", user.key().as_ref()],
        bump
    )]
    pub primary_name: Account<'info, PrimaryNameRegistry>,
    
    #[account(
        mut,
        constraint = user_token_account.owner == user.key(),
        constraint = user_token_account.mint == mint.key()
    )]
    pub user_token_account: Account<'info, TokenAccount>,
    
    #[account(
        mut,
        constraint = treasury_token_account.mint == mint.key()
    )]
    pub treasury_token_account: Account<'info, TokenAccount>,
    
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(params: RegisterWithSigParams)]
pub struct RegisterNameWithSignature<'info> {
    #[account(mut)]
    pub relayer: Signer<'info>,
    
    #[account(
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,
    
    #[account(
        init,
        payer = relayer,
        space = 8 + 77 + params.name.len(),
        seeds = [b"name", params.name.as_bytes()],
        bump
    )]
    pub name_record: Account<'info, NameRecord>,
    
    #[account(
        init_if_needed,
        payer = relayer,
    // Allocate max to allow future longer primary names without resize
    space = PRIMARY_NAME_ACCOUNT_SPACE,
        seeds = [b"primary", params.owner.as_ref()],
        bump
    )]
    pub primary_name: Account<'info, PrimaryNameRegistry>,
    #[account(
        seeds = [b"relayer", relayer.key().as_ref()],
        bump = relayer_entry.bump
    )]
    pub relayer_entry: Account<'info, RelayerEntry>,
    
    /// CHECK: Treasury receives the payment
    #[account(mut)]
    pub treasury: UncheckedAccount<'info>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(params: RegisterWithSigParams)]
pub struct RegisterNameWithSignatureToken<'info> {
    #[account(mut)]
    pub relayer: Signer<'info>,

    #[account(
        seeds = [b"config"],
        bump = config.bump
    )]
    pub config: Account<'info, RegistryConfig>,

    pub mint: Account<'info, Mint>,

    #[account(
        constraint = token_fee.mint == mint.key() @ ErrorCode::TokenNotEnabled,
        seeds = [b"token_fee", mint.key().as_ref()],
        bump = token_fee.bump
    )]
    pub token_fee: Account<'info, TokenFeeConfig>,

    #[account(
        init,
        payer = relayer,
        space = 8 + 77 + params.name.len(),
        seeds = [b"name", params.name.as_bytes()],
        bump
    )]
    pub name_record: Account<'info, NameRecord>,

    #[account(
        init_if_needed,
        payer = relayer,
        space = PRIMARY_NAME_ACCOUNT_SPACE,
        seeds = [b"primary", params.owner.as_ref()],
        bump
    )]
    pub primary_name: Account<'info, PrimaryNameRegistry>,
    #[account(
        seeds = [b"relayer", relayer.key().as_ref()],
        bump = relayer_entry.bump
    )]
    pub relayer_entry: Account<'info, RelayerEntry>,

    #[account(mut,
        constraint = relayer_token_account.owner == relayer.key(),
        constraint = relayer_token_account.mint == mint.key()
    )]
    pub relayer_token_account: Account<'info, TokenAccount>,

    #[account(mut,
        constraint = treasury_token_account.mint == mint.key()
    )]
    pub treasury_token_account: Account<'info, TokenAccount>,

    /// CHECK: Treasury for logging / potential SOL fallback
    #[account(mut)]
    pub treasury: UncheckedAccount<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(name: String)]
pub struct TransferName<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    
    #[account(
        mut,
        constraint = name_record.owner == owner.key() @ ErrorCode::Unauthorized,
        seeds = [b"name", name.as_bytes()],
        bump = name_record.bump
    )]
    pub name_record: Account<'info, NameRecord>,
}

#[derive(Accounts)]
#[instruction(name: String)]
pub struct SetResolvedAddress<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    
    #[account(
        mut,
        constraint = name_record.owner == owner.key() @ ErrorCode::Unauthorized,
        seeds = [b"name", name.as_bytes()],
        bump = name_record.bump
    )]
    pub name_record: Account<'info, NameRecord>,
}

#[derive(Accounts)]
#[instruction(name: String)]
pub struct SetPrimaryName<'info> {
    #[account(mut)]
    pub user: Signer<'info>,
    
    #[account(
        constraint = name_record.owner == user.key() @ ErrorCode::Unauthorized,
        seeds = [b"name", name.as_bytes()],
        bump = name_record.bump
    )]
    pub name_record: Account<'info, NameRecord>,
    
    #[account(
        init_if_needed,
        payer = user,
    // Allocate max to allow future longer primary names without resize
    space = PRIMARY_NAME_ACCOUNT_SPACE,
        seeds = [b"primary", user.key().as_ref()],
        bump
    )]
    pub primary_name: Account<'info, PrimaryNameRegistry>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AddRelayer<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        seeds = [b"config"],
        bump = config.bump,
        constraint = config.admin == admin.key() @ ErrorCode::Unauthorized
    )]
    pub config: Account<'info, RegistryConfig>,
    #[account(
        init,
        payer = admin,
        space = 8 + 32 + 1,
        seeds = [b"relayer", relayer.key().as_ref()],
        bump
    )]
    pub relayer_entry: Account<'info, RelayerEntry>,
    /// CHECK: relayer key for seeds
    pub relayer: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct RemoveRelayer<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        seeds = [b"config"],
        bump = config.bump,
        constraint = config.admin == admin.key() @ ErrorCode::Unauthorized
    )]
    pub config: Account<'info, RegistryConfig>,
    #[account(
        mut,
        close = admin,
        seeds = [b"relayer", relayer_entry.relayer.as_ref()],
        bump = relayer_entry.bump
    )]
    pub relayer_entry: Account<'info, RelayerEntry>,
}

// ========================================
// VALIDATION & UTILITIES
// ========================================

fn validate_name(name: &str) -> Result<()> {
    // Length check: 3-63 characters
    require!(name.len() >= 3 && name.len() <= 63, ErrorCode::InvalidNameLength);
    
    // Character validation
    for (i, c) in name.chars().enumerate() {
        let valid = c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-';
        require!(valid, ErrorCode::InvalidCharacter);
        
        // No leading/trailing hyphens
        if c == '-' {
            require!(i != 0 && i != name.len() - 1, ErrorCode::InvalidHyphenPlacement);
        }
    }
    
    // No consecutive hyphens
    require!(!name.contains("--"), ErrorCode::ConsecutiveHyphens);
    
    Ok(())
}

// ========================================
// ERROR CODES
// ========================================

#[error_code]
pub enum ErrorCode {
    #[msg("Invalid name length (3-63 characters required)")]
    InvalidNameLength,
    #[msg("Invalid character in name (a-z, 0-9, - only)")]
    InvalidCharacter,
    #[msg("Invalid hyphen placement (no leading/trailing hyphens)")]
    InvalidHyphenPlacement,
    #[msg("Consecutive hyphens not allowed")]
    ConsecutiveHyphens,
    #[msg("Name already exists")]
    NameAlreadyExists,
    #[msg("Name not found")]
    NameNotFound,
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("Invalid referrer basis points (max 10000)")]
    InvalidReferrerBps,
    #[msg("Invalid signature")]
    InvalidSignature,
    #[msg("Deadline expired")]
    DeadlineExpired,
    #[msg("Invalid nonce")]
    InvalidNonce,
    #[msg("Token not enabled")]
    TokenNotEnabled,
    #[msg("Insufficient token balance")]
    InsufficientTokenBalance,
    #[msg("Relayer not allowed")]
    RelayerNotAllowed,
    #[msg("Invalid treasury address")]
    InvalidTreasuryAddress,
    #[msg("Token fee amount mismatch")]
    TokenFeeMismatch,
}
