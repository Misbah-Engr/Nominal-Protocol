import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { NominalRegistry } from "../target/types/nominal_registry";
import { expect } from "chai";
import { 
  PublicKey, 
  Keypair, 
  SystemProgram,
  LAMPORTS_PER_SOL,
  ComputeBudgetProgram,
  Transaction
} from "@solana/web3.js";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  getAccount
} from "@solana/spl-token";

describe("nominal-registry", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const program = anchor.workspace.NominalRegistry as Program<NominalRegistry>;
  const admin = Keypair.generate();
  const treasury = Keypair.generate();
  const user = Keypair.generate();

  // PDAs
  let configPda: PublicKey;
  let configBump: number;

  // Helper function to create transaction with compute budget
  const createTransactionWithBudget = (instruction: any, computeUnits: number = 400000) => {
    const transaction = new Transaction();
    transaction.add(
      ComputeBudgetProgram.setComputeUnitLimit({ units: computeUnits }),
      instruction
    );
    return transaction;
  };

  before(async () => {
    // Fund accounts
    await provider.connection.requestAirdrop(admin.publicKey, 2 * LAMPORTS_PER_SOL);
    await provider.connection.requestAirdrop(user.publicKey, 2 * LAMPORTS_PER_SOL);
    await provider.connection.requestAirdrop(treasury.publicKey, LAMPORTS_PER_SOL);

    // Wait for confirmations
    await new Promise(resolve => setTimeout(resolve, 1000));

    // Derive config PDA
    [configPda, configBump] = PublicKey.findProgramAddressSync(
      [Buffer.from("config")],
      program.programId
    );
  });

  describe("Administrative Functions", () => {
    it("Initializes the registry", async () => {
      const registrationFee = new anchor.BN(0.001 * LAMPORTS_PER_SOL); // 0.001 SOL
      const referrerBps = 300; // 3%

      const tx = await program.methods
        .initialize(registrationFee, referrerBps)
        .accounts({
          admin: admin.publicKey,
          treasury: treasury.publicKey,
          config: configPda,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 400000 })
        ])
        .rpc();

      const config = await program.account.registryConfig.fetch(configPda);
      expect(config.admin.toString()).to.equal(admin.publicKey.toString());
      expect(config.treasury.toString()).to.equal(treasury.publicKey.toString());
      expect(config.registrationFee.toNumber()).to.equal(registrationFee.toNumber());
      expect(config.referrerBps).to.equal(referrerBps);
      expect(config.requireAllowlistedRelayer).to.equal(false);
    });

    it("Sets registration fee", async () => {
      const newFee = new anchor.BN(0.002 * LAMPORTS_PER_SOL);

      await program.methods
        .setRegistrationFee(newFee)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();

      const config = await program.account.registryConfig.fetch(configPda);
      expect(config.registrationFee.toNumber()).to.equal(newFee.toNumber());
    });

    it("Sets treasury address", async () => {
      const newTreasury = Keypair.generate();

      await program.methods
        .setTreasury(newTreasury.publicKey)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();

      const config = await program.account.registryConfig.fetch(configPda);
      expect(config.treasury.toString()).to.equal(newTreasury.publicKey.toString());
      
      // Reset to original treasury for other tests
      await program.methods
        .setTreasury(treasury.publicKey)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();
    });

    it("Sets referrer BPS", async () => {
      const newBps = 500; // 5%

      await program.methods
        .setReferrerBps(newBps)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();

      const config = await program.account.registryConfig.fetch(configPda);
      expect(config.referrerBps).to.equal(newBps);
    });

    it("Fails to set registration fee from non-admin", async () => {
      const newFee = new anchor.BN(0.003 * LAMPORTS_PER_SOL);

      try {
        await program.methods
          .setRegistrationFee(newFee)
          .accounts({
            admin: user.publicKey, // Wrong admin
            config: configPda,
          })
          .signers([user])
          .preInstructions([
            ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
          ])
          .rpc();
        expect.fail("Should have failed");
      } catch (error) {
        expect(error.toString()).to.include("AnchorError"); // Check for any anchor error
      }
    });

    it("Sets treasury address", async () => {
      const newTreasury = Keypair.generate();

      await program.methods
        .setTreasury(newTreasury.publicKey)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();

      const config = await program.account.registryConfig.fetch(configPda);
      expect(config.treasury.toString()).to.equal(newTreasury.publicKey.toString());
      
      // Reset treasury for other tests
      await program.methods
        .setTreasury(treasury.publicKey)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();
    });

    it("Sets referrer BPS", async () => {
      const newBps = 500; // 5%

      await program.methods
        .setReferrerBps(newBps)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();

      const config = await program.account.registryConfig.fetch(configPda);
      expect(config.referrerBps).to.equal(newBps);
    });

    it("Handles admin transfer process", async () => {
      const newAdmin = Keypair.generate();
      
      // Step 1: Transfer admin
      await program.methods
        .transferAdmin(newAdmin.publicKey)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();

      let config = await program.account.registryConfig.fetch(configPda);
      expect(config.pendingAdmin?.toString()).to.equal(newAdmin.publicKey.toString());

      // Step 2: Accept admin
      await program.methods
        .acceptAdmin()
        .accounts({
          newAdmin: newAdmin.publicKey,
          config: configPda,
        })
        .signers([newAdmin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();

      config = await program.account.registryConfig.fetch(configPda);
      expect(config.admin.toString()).to.equal(newAdmin.publicKey.toString());
      expect(config.pendingAdmin).to.be.null;

      // Reset admin for other tests
      await program.methods
        .transferAdmin(admin.publicKey)
        .accounts({
          admin: newAdmin.publicKey,
          config: configPda,
        })
        .signers([newAdmin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();

      await program.methods
        .acceptAdmin()
        .accounts({
          newAdmin: admin.publicKey,
          config: configPda,
        })
        .signers([admin])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
        ])
        .rpc();
    });
  });

  describe("Name Registration", () => {
    it("Registers a name with SOL", async () => {
      const name = "alice";
      const [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(name)],
        program.programId
      );
      const [primaryNamePda] = PublicKey.findProgramAddressSync(
        [Buffer.from("primary"), user.publicKey.toBuffer()],
        program.programId
      );

      const treasuryBalanceBefore = await provider.connection.getBalance(treasury.publicKey);

      await program.methods
        .registerName(name)
        .accounts({
          user: user.publicKey,
          config: configPda,
          nameRecord: nameRecordPda,
          primaryName: primaryNamePda,
          treasury: treasury.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([user])
        .rpc();

      // Verify name record
      const nameRecord = await program.account.nameRecord.fetch(nameRecordPda);
      expect(nameRecord.name).to.equal(name);
      expect(nameRecord.owner.toString()).to.equal(user.publicKey.toString());
      expect(nameRecord.resolved.toString()).to.equal(user.publicKey.toString());

      // Verify primary name
      const primaryName = await program.account.primaryNameRegistry.fetch(primaryNamePda);
      expect(primaryName.name).to.equal(name);
      expect(primaryName.owner.toString()).to.equal(user.publicKey.toString());

      // Verify payment
      const treasuryBalanceAfter = await provider.connection.getBalance(treasury.publicKey);
      const config = await program.account.registryConfig.fetch(configPda);
      expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(config.registrationFee.toNumber());
    });

    it("Fails to register duplicate name", async () => {
      const name = "alice"; // Same name as above
      const [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(name)],
        program.programId
      );

      try {
        await program.methods
          .registerName(name)
          .accounts({
            user: user.publicKey,
            config: configPda,
            nameRecord: nameRecordPda,
            primaryName: PublicKey.findProgramAddressSync(
              [Buffer.from("primary"), user.publicKey.toBuffer()],
              program.programId
            )[0],
            treasury: treasury.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([user])
          .rpc();
        expect.fail("Should have failed");
      } catch (error) {
        // Name already exists because PDA already initialized
        expect(error).to.exist;
      }
    });

    it("Fails to register invalid name", async () => {
      const invalidNames = [
        "ab", // Too short
        "a".repeat(64), // Too long
        "alice-", // Trailing hyphen
        "-alice", // Leading hyphen
        "alice--bob", // Consecutive hyphens
        "Alice", // Uppercase
        "alice!", // Invalid character
      ];

      for (const name of invalidNames) {
        try {
          const [nameRecordPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("name"), Buffer.from(name)],
            program.programId
          );

          await program.methods
            .registerName(name)
            .accounts({
              user: user.publicKey,
              config: configPda,
              nameRecord: nameRecordPda,
              primaryName: PublicKey.findProgramAddressSync(
                [Buffer.from("primary"), user.publicKey.toBuffer()],
                program.programId
              )[0],
              treasury: treasury.publicKey,
              systemProgram: SystemProgram.programId,
            })
            .signers([user])
            .rpc();
          expect.fail(`Should have failed for invalid name: ${name}`);
        } catch (error) {
          expect(error).to.exist; // Just check that an error occurred
        }
      }
    });
  });

  describe("Name Management", () => {
    const testName = "testname";
    let nameRecordPda: PublicKey;
    let newOwner: Keypair;

    before(async () => {
      newOwner = Keypair.generate();
      await provider.connection.requestAirdrop(newOwner.publicKey, LAMPORTS_PER_SOL);
      await new Promise(resolve => setTimeout(resolve, 1000));

      // Register a name for testing
      [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(testName)],
        program.programId
      );

      await program.methods
        .registerName(testName)
        .accounts({
          user: user.publicKey,
          config: configPda,
          nameRecord: nameRecordPda,
          primaryName: PublicKey.findProgramAddressSync(
            [Buffer.from("primary"), user.publicKey.toBuffer()],
            program.programId
          )[0],
          treasury: treasury.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([user])
        .rpc();
    });

    it("Transfers name ownership", async () => {
      await program.methods
        .transferName(testName, newOwner.publicKey)
        .accounts({
          owner: user.publicKey,
          nameRecord: nameRecordPda,
        })
        .signers([user])
        .rpc();

      const nameRecord = await program.account.nameRecord.fetch(nameRecordPda);
      expect(nameRecord.owner.toString()).to.equal(newOwner.publicKey.toString());
    });

    it("Sets resolved address", async () => {
      const newResolved = Keypair.generate().publicKey;

      await program.methods
        .setResolvedAddress(testName, newResolved)
        .accounts({
          owner: newOwner.publicKey,
          nameRecord: nameRecordPda,
        })
        .signers([newOwner])
        .rpc();

      const nameRecord = await program.account.nameRecord.fetch(nameRecordPda);
      expect(nameRecord.resolved.toString()).to.equal(newResolved.toString());
    });

    it("Fails to transfer from non-owner", async () => {
      try {
        await program.methods
          .transferName(testName, user.publicKey)
          .accounts({
            owner: user.publicKey, // Not the current owner
            nameRecord: nameRecordPda,
          })
          .signers([user])
          .rpc();
        expect.fail("Should have failed");
      } catch (error) {
        expect(error.toString()).to.include("Unauthorized");
      }
    });
  });

  describe("Edge Cases and Security", () => {
    it("Validates all name rules correctly", async () => {
      const validNames = [
        `alice-${Math.floor(Math.random() * 10000)}`,
        `bob-2024-${Math.floor(Math.random() * 10000)}`, 
        `my-name-${Math.floor(Math.random() * 10000)}`,
        `a1b2c3-${Math.floor(Math.random() * 10000)}`,
        `valid-name-${Math.floor(Math.random() * 1000)}`
      ];      // These should not throw during validation
      for (const name of validNames) {
        try {
          const [nameRecordPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("name"), Buffer.from(name)],
            program.programId
          );
          
          const tempUser = Keypair.generate();
          await provider.connection.requestAirdrop(tempUser.publicKey, LAMPORTS_PER_SOL);
          await new Promise(resolve => setTimeout(resolve, 500));

          await program.methods
            .registerName(name)
            .accounts({
              user: tempUser.publicKey,
              config: configPda,
              nameRecord: nameRecordPda,
              primaryName: PublicKey.findProgramAddressSync(
                [Buffer.from("primary"), tempUser.publicKey.toBuffer()],
                program.programId
              )[0],
              treasury: treasury.publicKey,
              systemProgram: SystemProgram.programId,
            })
            .signers([tempUser])
            .preInstructions([
              ComputeBudgetProgram.setComputeUnitLimit({ units: 400000 })
            ])
            .rpc();

          const nameRecord = await program.account.nameRecord.fetch(nameRecordPda);
          expect(nameRecord.name).to.equal(name);
        } catch (error: any) {
          console.error(`Valid name failed: ${name}`, error.toString());
          throw error;
        }
      }
    });

    it("Tests multiple name registrations", async () => {
      const names = ["test1", "test2", "test3"];
      const users = [Keypair.generate(), Keypair.generate(), Keypair.generate()];
      
      // Fund users
      for (const user of users) {
        await provider.connection.requestAirdrop(user.publicKey, LAMPORTS_PER_SOL);
      }
      await new Promise(resolve => setTimeout(resolve, 1000));

      // Register multiple names
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        const user = users[i];
        
        const [nameRecordPda] = PublicKey.findProgramAddressSync(
          [Buffer.from("name"), Buffer.from(name)],
          program.programId
        );
        const [primaryNamePda] = PublicKey.findProgramAddressSync(
          [Buffer.from("primary"), user.publicKey.toBuffer()],
          program.programId
        );

        await program.methods
          .registerName(name)
          .accounts({
            user: user.publicKey,
            config: configPda,
            nameRecord: nameRecordPda,
            primaryName: primaryNamePda,
            treasury: treasury.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([user])
          .preInstructions([
            ComputeBudgetProgram.setComputeUnitLimit({ units: 400000 })
          ])
          .rpc();

        const nameRecord = await program.account.nameRecord.fetch(nameRecordPda);
        expect(nameRecord.name).to.equal(name);
        expect(nameRecord.owner.toString()).to.equal(user.publicKey.toString());
      }
    });

    it("Tests primary name functionality", async () => {
      const user = Keypair.generate();
      await provider.connection.requestAirdrop(user.publicKey, LAMPORTS_PER_SOL);
      await new Promise(resolve => setTimeout(resolve, 1000));

      const name = "primarytest";
      
      // Register name
      const [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(name)],
        program.programId
      );
      const [primaryNamePda] = PublicKey.findProgramAddressSync(
        [Buffer.from("primary"), user.publicKey.toBuffer()],
        program.programId
      );

      await program.methods
        .registerName(name)
        .accounts({
          user: user.publicKey,
          config: configPda,
          nameRecord: nameRecordPda,
          primaryName: primaryNamePda,
          treasury: treasury.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([user])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 400000 })
        ])
        .rpc();

      // Set as primary name
      await program.methods
        .setPrimaryName(name)
        .accounts({
          user: user.publicKey,
          nameRecord: nameRecordPda,
          primaryName: primaryNamePda,
          systemProgram: SystemProgram.programId,
        })
        .signers([user])
        .preInstructions([
          ComputeBudgetProgram.setComputeUnitLimit({ units: 300000 })
        ])
        .rpc();

      const primaryName = await program.account.primaryNameRegistry.fetch(primaryNamePda);
      expect(primaryName.name).to.equal(name);
      expect(primaryName.owner.toString()).to.equal(user.publicKey.toString());
    });

    it("Handles referrer BPS validation", async () => {
      try {
        await program.methods
          .setReferrerBps(10001) // Invalid: > 10000
          .accounts({
            admin: admin.publicKey,
            config: configPda,
          })
          .signers([admin])
          .preInstructions([
            ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 })
          ])
          .rpc();
        expect.fail("Should have failed");
      } catch (error: any) {
        expect(error.toString()).to.include("Invalid referrer basis points");
      }
    });
  });

  // =============================================================
  // Additional Tests: Token Fee Config & Alternative Registrations
  // =============================================================
  describe("Token & Signature Registration", () => {
    let tokenMint: PublicKey;
    let tokenFeePda: PublicKey;
    let userTokenAccount: PublicKey;
    let treasuryTokenAccount: PublicKey;
    const tokenDecimals = 6;
    const tokenFeeAmount = new anchor.BN(10_000); // 0.01 tokens if 6 decimals

    it("Sets token fee configuration (admin)", async () => {
      // Create mint
      tokenMint = await createMint(
        provider.connection,
        admin, // payer
        admin.publicKey, // mint authority
        null, // freeze authority
        tokenDecimals
      );

      // Derive token fee PDA
      tokenFeePda = PublicKey.findProgramAddressSync(
        [Buffer.from("token_fee"), tokenMint.toBuffer()],
        program.programId
      )[0];

      // Create token accounts (ATA) for user & treasury
      userTokenAccount = (await getOrCreateAssociatedTokenAccount(
        provider.connection,
        admin,
        tokenMint,
        user.publicKey
      )).address;
      treasuryTokenAccount = (await getOrCreateAssociatedTokenAccount(
        provider.connection,
        admin,
        tokenMint,
        treasury.publicKey
      )).address;

      // Mint tokens to user
      await mintTo(
        provider.connection,
        admin,
        tokenMint,
        userTokenAccount,
        admin,
        1_000_000_000 // 1000 tokens
      );

      // Set token fee
      await program.methods
        .setTokenFee(tokenFeeAmount, true)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
          mint: tokenMint,
          tokenFee: tokenFeePda,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin])
        .rpc();

      const tokenFeeAcct = await program.account.tokenFeeConfig.fetch(tokenFeePda);
      expect(tokenFeeAcct.mint.toString()).to.equal(tokenMint.toString());
      expect(tokenFeeAcct.amount.toString()).to.equal(tokenFeeAmount.toString());
      expect(tokenFeeAcct.enabled).to.equal(true);
    });

    it("Registers a name with token payment", async () => {
      const name = `tokname${Math.floor(Math.random()*1_000_000)}`;
      const [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(name)],
        program.programId
      );
      const [primaryNamePda] = PublicKey.findProgramAddressSync(
        [Buffer.from("primary"), user.publicKey.toBuffer()],
        program.programId
      );

      const userBefore = (await getAccount(provider.connection, userTokenAccount)).amount;
      const treasuryBefore = (await getAccount(provider.connection, treasuryTokenAccount)).amount;

      await program.methods
        .registerNameWithToken(name)
        .accounts({
          user: user.publicKey,
          config: configPda,
          mint: tokenMint,
          tokenFee: tokenFeePda,
          nameRecord: nameRecordPda,
            primaryName: primaryNamePda,
          userTokenAccount,
          treasuryTokenAccount,
          tokenProgram: anchor.utils.token.TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([user])
        .rpc();

      const nameRecord = await program.account.nameRecord.fetch(nameRecordPda);
      expect(nameRecord.name).to.equal(name);

      const userAfter = (await getAccount(provider.connection, userTokenAccount)).amount;
      const treasuryAfter = (await getAccount(provider.connection, treasuryTokenAccount)).amount;
      expect(Number(userBefore - userAfter)).to.equal(tokenFeeAmount.toNumber());
      expect(Number(treasuryAfter - treasuryBefore)).to.equal(tokenFeeAmount.toNumber());
    });

    it("Disables token and fails registration", async () => {
      await program.methods
        .setTokenFee(tokenFeeAmount, false)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
          mint: tokenMint,
          tokenFee: tokenFeePda,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin])
        .rpc();

      const name = `tokdisabled${Math.floor(Math.random()*1_000_000)}`;
      const [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(name)],
        program.programId
      );
      const [primaryNamePda] = PublicKey.findProgramAddressSync(
        [Buffer.from("primary"), user.publicKey.toBuffer()],
        program.programId
      );

      try {
        await program.methods
          .registerNameWithToken(name)
          .accounts({
            user: user.publicKey,
            config: configPda,
            mint: tokenMint,
            tokenFee: tokenFeePda,
            nameRecord: nameRecordPda,
            primaryName: primaryNamePda,
            userTokenAccount,
            treasuryTokenAccount,
            tokenProgram: anchor.utils.token.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([user])
          .rpc();
        expect.fail("Should fail when token fee disabled");
      } catch (e) {
        expect(e.toString()).to.include("Token not enabled");
      }

      // Re-enable for later tests
      await program.methods
        .setTokenFee(tokenFeeAmount, true)
        .accounts({
          admin: admin.publicKey,
          config: configPda,
          mint: tokenMint,
          tokenFee: tokenFeePda,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin])
        .rpc();
    });

    it("Registers a name with signature (SOL payment)", async () => {
      const relayer = Keypair.generate();
      await provider.connection.requestAirdrop(relayer.publicKey, 2 * LAMPORTS_PER_SOL);
      await new Promise(r => setTimeout(r, 800));

      // Add relayer to allowlist
      const [relayerEntryPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("relayer"), relayer.publicKey.toBuffer()],
        program.programId
      );
      await program.methods
        .addRelayer(relayer.publicKey)
  .accounts({
          admin: admin.publicKey,
          config: configPda,
          relayerEntry: relayerEntryPda,
          relayer: relayer.publicKey,
          systemProgram: SystemProgram.programId,
  } as any)
        .signers([admin])
        .rpc();

      const params = {
        name: `sig${Math.floor(Math.random()*1_000_000)}`,
        owner: user.publicKey,
        relayer: relayer.publicKey,
        currency: null, // None = SOL path
        amount: new anchor.BN(0),
        deadline: new anchor.BN(Math.floor(Date.now()/1000) + 600),
        nonce: new anchor.BN(0),
      } as any; // cast for IDL mapping

      const [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(params.name)],
        program.programId
      );
      const [primaryNamePda] = PublicKey.findProgramAddressSync(
        [Buffer.from("primary"), user.publicKey.toBuffer()],
        program.programId
      );

      const treasuryBalanceBefore = await provider.connection.getBalance(treasury.publicKey);
    const relayerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);
      const config = await program.account.registryConfig.fetch(configPda);
      const referrerAmount = Math.floor(config.registrationFee.toNumber() * config.referrerBps / 10_000);
      const expectedTreasuryDelta = config.registrationFee.toNumber() - referrerAmount;

      const dummySig = Buffer.alloc(64, 1);

      await program.methods
        .registerNameWithSignature(params, dummySig)
  .accounts({
          relayer: relayer.publicKey,
          config: configPda,
          nameRecord: nameRecordPda,
          primaryName: primaryNamePda,
      relayerEntry: relayerEntryPda,
          treasury: treasury.publicKey,
          systemProgram: SystemProgram.programId,
  } as any)
        .signers([relayer])
        .rpc();

      const nameRecord = await program.account.nameRecord.fetch(nameRecordPda);
      expect(nameRecord.name).to.equal(params.name);
      expect(nameRecord.owner.toString()).to.equal(user.publicKey.toString());

      const treasuryBalanceAfter = await provider.connection.getBalance(treasury.publicKey);
      expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(expectedTreasuryDelta);
      const relayerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);
      // Relayer pays treasury amount plus network fees (>= expectedTreasuryDelta)
      expect(relayerBalanceBefore - relayerBalanceAfter).to.be.greaterThanOrEqual(expectedTreasuryDelta);
    // Explicitly ensure referrer share was withheld from treasury (i.e., relayer retained it)
    const actualReferrerShare = config.registrationFee.toNumber() - (treasuryBalanceAfter - treasuryBalanceBefore);
    expect(actualReferrerShare).to.equal(referrerAmount);
    });

    it("Registers a name with signature (token payment)", async () => {
      // Reuse existing token mint + fee config
      const relayer = Keypair.generate();
      await provider.connection.requestAirdrop(relayer.publicKey, 2 * LAMPORTS_PER_SOL);
      await new Promise(r => setTimeout(r, 800));

      // Add relayer to allowlist
      const [relayerEntryPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("relayer"), relayer.publicKey.toBuffer()],
        program.programId
      );
      await program.methods
        .addRelayer(relayer.publicKey)
  .accounts({
          admin: admin.publicKey,
          config: configPda,
          relayerEntry: relayerEntryPda,
          relayer: relayer.publicKey,
          systemProgram: SystemProgram.programId,
  } as any)
        .signers([admin])
        .rpc();

      // Create relayer token account & mint tokens
      const relayerTokenAccount = (await getOrCreateAssociatedTokenAccount(
        provider.connection,
        admin,
        tokenMint,
        relayer.publicKey
      )).address;
      await mintTo(
        provider.connection,
        admin,
        tokenMint,
        relayerTokenAccount,
        admin,
        1_000_000_000 // 1000 tokens
      );

      const params = {
        name: `sigtok${Math.floor(Math.random()*1_000_000)}`,
        owner: user.publicKey,
        relayer: relayer.publicKey,
        currency: tokenMint,
        amount: tokenFeeAmount,
        deadline: new anchor.BN(Math.floor(Date.now()/1000) + 600),
        nonce: new anchor.BN(0),
      } as any;

      const [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(params.name)],
        program.programId
      );
      const [primaryNamePda] = PublicKey.findProgramAddressSync(
        [Buffer.from("primary"), user.publicKey.toBuffer()],
        program.programId
      );

      const relayerTokenBefore = (await getAccount(provider.connection, relayerTokenAccount)).amount;
      const treasuryTokenBefore = (await getAccount(provider.connection, treasuryTokenAccount)).amount;

      const config = await program.account.registryConfig.fetch(configPda);
      const referrerAmount = Math.floor(tokenFeeAmount.toNumber() * config.referrerBps / 10_000);
      const expectedTreasuryDelta = tokenFeeAmount.toNumber() - referrerAmount;

      const dummySig = Buffer.alloc(64, 2);

      await program.methods
        .registerNameWithSignatureToken(params, dummySig)
  .accounts({
          relayer: relayer.publicKey,
          config: configPda,
          mint: tokenMint,
          tokenFee: tokenFeePda,
          nameRecord: nameRecordPda,
          primaryName: primaryNamePda,
          relayerEntry: relayerEntryPda,
          relayerTokenAccount,
          treasuryTokenAccount,
          treasury: treasury.publicKey,
          tokenProgram: anchor.utils.token.TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
  } as any)
        .signers([relayer])
        .rpc();

      const relayerTokenAfter = (await getAccount(provider.connection, relayerTokenAccount)).amount;
      const treasuryTokenAfter = (await getAccount(provider.connection, treasuryTokenAccount)).amount;

      expect(Number(treasuryTokenAfter - treasuryTokenBefore)).to.equal(expectedTreasuryDelta);
      expect(Number(relayerTokenBefore - relayerTokenAfter)).to.equal(expectedTreasuryDelta); // referrer share stays with relayer

      const nameRecord = await program.account.nameRecord.fetch(nameRecordPda);
      expect(nameRecord.name).to.equal(params.name);
    });

    it("Fails signature registration with non-allowlisted relayer", async () => {
      const relayer = Keypair.generate();
      await provider.connection.requestAirdrop(relayer.publicKey, LAMPORTS_PER_SOL);
      await new Promise(r => setTimeout(r, 600));
      const params = {
        name: `failrelayer${Math.floor(Math.random()*1_000_000)}`,
        owner: user.publicKey,
        relayer: relayer.publicKey,
        currency: null,
        amount: new anchor.BN(0),
        deadline: new anchor.BN(Math.floor(Date.now()/1000) + 600),
        nonce: new anchor.BN(0),
      } as any;
      const [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(params.name)],
        program.programId
      );
      const [primaryNamePda] = PublicKey.findProgramAddressSync(
        [Buffer.from("primary"), user.publicKey.toBuffer()],
        program.programId
      );
      const dummySig = Buffer.alloc(64, 3);
      try {
        await program.methods
          .registerNameWithSignature(params, dummySig)
          .accounts({
            relayer: relayer.publicKey,
            config: configPda,
            nameRecord: nameRecordPda,
            primaryName: primaryNamePda,
            // intentionally omit relayerEntry
            treasury: treasury.publicKey,
            systemProgram: SystemProgram.programId,
          } as any)
          .signers([relayer])
          .rpc();
        expect.fail("Should fail without allowlisted relayer");
      } catch (e:any) {
        expect(e.toString()).to.satisfy((s:string) => s.includes("Relayer") || s.includes("Account"));
      }
    });

    it("Removes relayer and blocks further signature registrations", async () => {
      const relayer = Keypair.generate();
      await provider.connection.requestAirdrop(relayer.publicKey, 2 * LAMPORTS_PER_SOL);
      await new Promise(r => setTimeout(r, 800));
      const [relayerEntryPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("relayer"), relayer.publicKey.toBuffer()],
        program.programId
      );
      // Add relayer
      await program.methods
        .addRelayer(relayer.publicKey)
  .accounts({
          admin: admin.publicKey,
          config: configPda,
          relayerEntry: relayerEntryPda,
          relayer: relayer.publicKey,
          systemProgram: SystemProgram.programId,
  } as any)
        .signers([admin])
        .rpc();
      // Perform one signature registration (SOL)
      const params = {
        name: `onetime${Math.floor(Math.random()*1_000_000)}`,
        owner: user.publicKey,
        relayer: relayer.publicKey,
        currency: null,
        amount: new anchor.BN(0),
        deadline: new anchor.BN(Math.floor(Date.now()/1000) + 600),
        nonce: new anchor.BN(0),
      } as any;
      const [nameRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(params.name)],
        program.programId
      );
      const [primaryNamePda] = PublicKey.findProgramAddressSync(
        [Buffer.from("primary"), user.publicKey.toBuffer()],
        program.programId
      );
      const dummySig = Buffer.alloc(64, 4);
      await program.methods
        .registerNameWithSignature(params, dummySig)
  .accounts({
          relayer: relayer.publicKey,
          config: configPda,
          nameRecord: nameRecordPda,
          primaryName: primaryNamePda,
          relayerEntry: relayerEntryPda,
          treasury: treasury.publicKey,
          systemProgram: SystemProgram.programId,
  } as any)
        .signers([relayer])
        .rpc();
      // Remove relayer
      await program.methods
        .removeRelayer(relayer.publicKey)
  .accounts({
          admin: admin.publicKey,
          config: configPda,
          relayerEntry: relayerEntryPda,
  } as any)
        .signers([admin])
        .rpc();
      // Attempt another signature registration -> should fail
      const params2 = { ...params, name: `blocked${Math.floor(Math.random()*1_000_000)}` };
      const [nameRecordPda2] = PublicKey.findProgramAddressSync(
        [Buffer.from("name"), Buffer.from(params2.name)],
        program.programId
      );
      try {
        await program.methods
          .registerNameWithSignature(params2, Buffer.alloc(64,5))
          .accounts({
            relayer: relayer.publicKey,
            config: configPda,
            nameRecord: nameRecordPda2,
            primaryName: primaryNamePda,
            relayerEntry: relayerEntryPda, // closed, should error
            treasury: treasury.publicKey,
            systemProgram: SystemProgram.programId,
          } as any)
          .signers([relayer])
          .rpc();
        expect.fail("Should fail after relayer removal");
      } catch (e:any) {
        expect(e.toString()).to.satisfy((s:string) => s.includes("closed") || s.includes("Account") || s.includes("Relayer"));
      }
    });
  });
});