# FolderSafe vault format

- [vault-format-v1.md](vault-format-v1.md) — the specification.
- [test-vectors/v1.json](test-vectors/v1.json) — public test vectors (keys, scrypt, AES-SIV, masterkey file, vault
  config, directory paths, names, file contents, recovery). The reference implementation checks them in `swift test`;
  `interop/run-interop.sh` re-checks the core part with Cryptomator's libraries.

License: the specification and the test vectors are licensed under
[Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).
Anyone may implement the format, in any software, under any license.
