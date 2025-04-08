const crypto = require('crypto');
const fs = require('fs');
const keccak256 = require('keccak256'); // You may need to install this: npm install keccak256

// Read PEM file
const pemContent = fs.readFileSync('../public-key.pem', 'utf8');

// Extract the public key bytes from PEM
const publicKeyPem = pemContent
  .replace('-----BEGIN PUBLIC KEY-----', '')
  .replace('-----END PUBLIC KEY-----', '')
  .replace(/\n/g, '');

// Decode base64 to get DER format
const derBuffer = Buffer.from(publicKeyPem, 'base64');

// Parse the DER to get the actual public key (this is a simplified version)
// For ECDSA keys, we need to extract the actual key point from the ASN.1 structure
// This is a simplification - you might need a proper ASN.1 parser for production
const publicKeyBytes = derBuffer.slice(derBuffer.indexOf(Buffer.from([0x04])));

// Compute Ethereum address (keccak256 hash of public key, minus first byte, take last 20 bytes)
const address = '0x' + keccak256(publicKeyBytes).slice(-20).toString('hex');

console.log('Ethereum Address:', address);