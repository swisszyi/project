import { FHELendingPlatform, FHELendingPlatform__factory } from "../types";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import { Contract, Signer } from "ethers";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

// Mock ERC20 Token for testing
const ERC20Mock = require("@openzeppelin/contracts/build/contracts/ERC20Mock.json");

type Signers = {
  deployer: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
  carol: HardhatEthersSigner;
};

async function deployFixture() {
  const [deployer, alice, bob, carol] = await ethers.getSigners();
  
  // Deploy mock tokens
  const TokenFactory = new ethers.ContractFactory(
    ERC20Mock.abi,
    ERC20Mock.bytecode,
    deployer
  );
  
  const token1 = await TokenFactory.deploy("Test Token 1", "TT1", deployer.address, ethers.parseEther("1000000"));
  const token2 = await TokenFactory.deploy("Test Token 2", "TT2", deployer.address, ethers.parseEther("1000000"));

  // Deploy FHE Lending Platform
  const factory = (await ethers.getContractFactory("FHELendingPlatform")) as FHELendingPlatform__factory;
  const lendingPlatform = (await factory.deploy()) as FHELendingPlatform;
  const lendingPlatformAddress = await lendingPlatform.getAddress();

  return { 
    lendingPlatform, 
    lendingPlatformAddress,
    token1,
    token2,
    signers: { deployer, alice, bob, carol } 
  };
}

describe("FHELendingPlatform", function () {
  let lendingPlatform: FHELendingPlatform;
  let lendingPlatformAddress: string;
  let token1: Contract;
  let token2: Contract;
  let signers: Signers;

  before(async function () {
    ({ lendingPlatform, lendingPlatformAddress, token1, token2, signers } = await loadFixture(deployFixture));
    
    // Distribute tokens to test users
    await token1.transfer(signers.alice.address, ethers.parseEther("1000"));
    await token1.transfer(signers.bob.address, ethers.parseEther("1000"));
    await token2.transfer(signers.alice.address, ethers.parseEther("1000"));
    await token2.transfer(signers.bob.address, ethers.parseEther("1000"));
  });

  it("should be deployed", async function () {
    console.log(`FHELendingPlatform deployed at: ${lendingPlatformAddress}`);
    expect(ethers.isAddress(lendingPlatformAddress)).to.eq(true);
  });

  describe("Token Management", function () {
    it("owner can add supported tokens", async function () {
      const tx = await lendingPlatform.connect(signers.deployer).addToken(
        await token1.getAddress(),
        await fhevm.createEncryptedUint32(500) // 5% APR
      );
      await tx.wait();
      
      const tx2 = await lendingPlatform.connect(signers.deployer).addToken(
        await token2.getAddress(),
        await fhevm.createEncryptedUint32(300) // 3% APR
      );
      await tx2.wait();
      
      const tokens = await lendingPlatform.getSupportedTokens();
      expect(tokens.length).to.equal(2);
      expect(tokens[0]).to.equal(await token1.getAddress());
      expect(tokens[1]).to.equal(await token2.getAddress());
    });

    it("non-owner cannot add tokens", async function () {
      await expect(
        lendingPlatform.connect(signers.alice).addToken(
          await token1.getAddress(),
          await fhevm.createEncryptedUint32(500)
        )
      ).to.be.revertedWith("Only owner can call this function");
    });
  });

  describe("Deposit & Withdraw", function () {
    it("user can deposit tokens", async function () {
      const tokenAddress = await token1.getAddress();
      const depositAmount = ethers.parseEther("100");
      
      // Approve lending platform to spend tokens
      await token1.connect(signers.alice).approve(lendingPlatformAddress, depositAmount);
      
      // Encrypt deposit amount
      const encryptedDeposit = await fhevm
        .createEncryptedInput(lendingPlatformAddress, signers.alice.address)
        .add256(depositAmount)
        .encrypt();
      
      // Perform deposit
      const tx = await lendingPlatform.connect(signers.alice).deposit(
        tokenAddress,
        encryptedDeposit.handles[0],
        encryptedDeposit.inputProof
      );
      await tx.wait();
      
      // Check token balance transferred
      expect(await token1.balanceOf(lendingPlatformAddress)).to.equal(depositAmount);
      expect(await token1.balanceOf(signers.alice.address)).to.equal(ethers.parseEther("900"));
    });

    it("user can withdraw tokens", async function () {
      const tokenAddress = await token1.getAddress();
      const withdrawAmount = ethers.parseEther("50");
      
      // Encrypt withdraw amount
      const encryptedWithdraw = await fhevm
        .createEncryptedInput(lendingPlatformAddress, signers.alice.address)
        .add256(withdrawAmount)
        .encrypt();
      
      // Perform withdraw
      const tx = await lendingPlatform.connect(signers.alice).withdraw(
        tokenAddress,
        encryptedWithdraw.handles[0],
        encryptedWithdraw.inputProof
      );
      await tx.wait();
      
      // Check token balance transferred back
      expect(await token1.balanceOf(lendingPlatformAddress)).to.equal(ethers.parseEther("50"));
      expect(await token1.balanceOf(signers.alice.address)).to.equal(ethers.parseEther("950"));
    });
  });

  describe("Borrow & Repay", function () {
    it("user can borrow against collateral", async function () {
      const collateralToken = await token1.getAddress();
      const borrowToken = await token2.getAddress();
      const depositAmount = ethers.parseEther("200");
      const borrowAmount = ethers.parseEther("100");
      
      // Alice deposits collateral (Token1)
      await token1.connect(signers.alice).approve(lendingPlatformAddress, depositAmount);
      const encryptedDeposit = await fhevm
        .createEncryptedInput(lendingPlatformAddress, signers.alice.address)
        .add256(depositAmount)
        .encrypt();
      await lendingPlatform.connect(signers.alice).deposit(
        collateralToken,
        encryptedDeposit.handles[0],
        encryptedDeposit.inputProof
      );
      
      // Alice borrows Token2
      const encryptedBorrow = await fhevm
        .createEncryptedInput(lendingPlatformAddress, signers.alice.address)
        .add256(borrowAmount)
        .encrypt();
      const tx = await lendingPlatform.connect(signers.alice).borrow(
        borrowToken,
        encryptedBorrow.handles[0],
        encryptedBorrow.inputProof
      );
      await tx.wait();
      
      // Check borrow token received
      expect(await token2.balanceOf(signers.alice.address)).to.equal(ethers.parseEther("1100"));
    });

    it("user cannot borrow more than collateral allows", async function () {
      const borrowToken = await token2.getAddress();
      const excessiveBorrow = ethers.parseEther("200"); // More than collateral allows
      
      const encryptedBorrow = await fhevm
        .createEncryptedInput(lendingPlatformAddress, signers.alice.address)
        .add256(excessiveBorrow)
        .encrypt();
      
      await expect(
        lendingPlatform.connect(signers.alice).borrow(
          borrowToken,
          encryptedBorrow.handles[0],
          encryptedBorrow.inputProof
        )
      ).to.be.revertedWith("Borrow would exceed collateral limit");
    });

    it("user can repay loan", async function () {
      const borrowToken = await token2.getAddress();
      const repayAmount = ethers.parseEther("50");
      
      // Approve repayment
      await token2.connect(signers.alice).approve(lendingPlatformAddress, repayAmount);
      
      // Encrypt repay amount
      const encryptedRepay = await fhevm
        .createEncryptedInput(lendingPlatformAddress, signers.alice.address)
        .add256(repayAmount)
        .encrypt();
      
      // Perform repay
      const tx = await lendingPlatform.connect(signers.alice).repay(
        borrowToken,
        encryptedRepay.handles[0],
        encryptedRepay.inputProof
      );
      await tx.wait();
      
      // Check token balance transferred
      expect(await token2.balanceOf(signers.alice.address)).to.equal(ethers.parseEther("1050"));
    });
  });

  describe("Liquidation", function () {
    it("liquidator can liquidate undercollateralized position", async function () {
      // Bob creates a position
      const collateralToken = await token1.getAddress();
      const borrowToken = await token2.getAddress();
      const depositAmount = ethers.parseEther("100");
      const borrowAmount = ethers.parseEther("80"); // Close to LTV limit
      
      // Bob deposits collateral
      await token1.connect(signers.bob).approve(lendingPlatformAddress, depositAmount);
      const encryptedDeposit = await fhevm
        .createEncryptedInput(lendingPlatformAddress, signers.bob.address)
        .add256(depositAmount)
        .encrypt();
      await lendingPlatform.connect(signers.bob).deposit(
        collateralToken,
        encryptedDeposit.handles[0],
        encryptedDeposit.inputProof
      );
      
      // Bob borrows
      const encryptedBorrow = await fhevm
        .createEncryptedInput(lendingPlatformAddress, signers.bob.address)
        .add256(borrowAmount)
        .encrypt();
      await lendingPlatform.connect(signers.bob).borrow(
        borrowToken,
        encryptedBorrow.handles[0],
        encryptedBorrow.inputProof
      );
      
      // Simulate collateral value drop by withdrawing some (making position undercollateralized)
      const encryptedWithdraw = await fhevm
        .createEncryptedInput(lendingPlatformAddress, signers.bob.address)
        .add256(ethers.parseEther("60"))
        .encrypt();
      await lendingPlatform.connect(signers.bob).withdraw(
        collateralToken,
        encryptedWithdraw.handles[0],
        encryptedWithdraw.inputProof
      );
      
      // Carol liquidates Bob's position
      const tx = await lendingPlatform.connect(signers.carol).liquidate(
        signers.bob.address,
        borrowToken
      );
      await tx.wait();
      
      // Check Carol received some collateral
      expect(await token1.balanceOf(signers.carol.address)).to.be.gt(0);
    });
  });
});
