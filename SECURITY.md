# Security policy

## Reporting a vulnerability

Please email **security@foldersafe.app** and do not open a public issue. Include:

- what is affected (vault format / FolderSafeCore, macOS app, iPhone app, File Provider or FSKit extension) and the version
  or commit;
- steps to reproduce, or a proof of concept;
- the impact you expect (for example: names or contents readable without the key, key material written to disk,
  a vault that FolderSafe or Cryptomator can no longer open).

We will acknowledge your report as soon as we can, keep you informed while we work on a fix, and credit you in the
release notes unless you prefer otherwise. Please give us reasonable time to ship a fix before disclosing publicly.

## In scope

- The vault format specification (`docs/spec/`) and the reference implementation (`client/foldersafe_apple_core/`):
  cryptographic mistakes, parsing bugs, anything that leaks names, contents or keys, or that corrupts vaults.
- Key handling in the apps: password / recovery phrase / device keys, the keychain items used while a vault is unlocked,
  keys or cleartext that survive locking when they should not (see [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)).
- The File Provider and FSKit extensions: access to a locked vault, access by other apps that shouldn't have it,
  sandbox escapes.
- Official signed builds from foldersafe.app and the App Store.

## Out of scope

These are documented limitations, not vulnerabilities:

- Reading a vault **while it is unlocked** from a process running as the same user (including root), or malware on a
  compromised device.
- Metadata visible in the ciphertext: number of files, approximate sizes, modification times (spec §9).
- Offline guessing of weak passwords.
- Losing both the password and the recovery phrase.
- Bugs in Cryptomator's own software, in cloud sync services, or in the operating system — please report those to their
  vendors (we are happy to help if a FolderSafe vault is involved).
- Social engineering, physical attacks on an unlocked device, denial of service on your own machine.
