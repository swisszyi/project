import fs from 'fs';
import path from 'path';

async function main() {
  const artifactPath = path.join(
    __dirname,
    '../artifacts/contracts/FHELendingPlatform.sol/FHELendingPlatform.json'
  );
  
  if (!fs.existsSync(artifactPath)) {
    throw new Error('Artifact not found! Run `npx hardhat compile` first');
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  console.log("Full ABI:", JSON.stringify(artifact.abi, null, 2));
  
  // Save ABI to a separate file
  fs.writeFileSync('FHELendingPlatformABI.json', JSON.stringify(artifact.abi));
  console.log('ABI saved to FHELendingPlatformABI.json');
}

main().catch(console.error);
