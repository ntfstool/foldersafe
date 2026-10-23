# Cryptomator interop harness (test only)

> **Licensing: TEST TOOL ONLY.** This harness links Cryptomator's `cryptofs` / `cryptolib` / `siv-mode`, which are
> licensed under the **AGPL-3.0**. It exists only to test FolderSafe's independent implementation of the vault format
> against the reference library. It must **never** be shipped with, bundled into, or linked from any FolderSafe client,
> and no Cryptomator source code may be copied into this repository.

A small command-line wrapper around `org.cryptomator:cryptofs` (the library the Cryptomator desktop app uses), so that
FolderSafe can check interop in both directions against vault format 8 / `SIV_GCM` (spec: `docs/spec/vault-format-v1.md`).

Versions: `cryptofs 2.9.0` + `cryptolib 2.2.1` — the newest stable release that runs on JDK 22
(`cryptofs` 2.10.0 and later are compiled for Java 25).

## Build and run

```sh
mvn -q -f interop/cryptomator/pom.xml package          # → interop/cryptomator/target/cryptomator-interop.jar
interop/cryptomator/run.sh selftest                    # builds the jar if missing, runs it with JDK 22
```

| Command | What it does |
|---|---|
| `create --vault DIR --password PW --source SRC` | `DIR` must not exist or be empty. Writes `masterkey.cryptomator` (library defaults: scrypt N=32768, r=8), `vault.cryptomator` (format 8, `SIV_GCM`, kid `masterkeyfile:masterkey.cryptomator`), then copies the tree `SRC` into the vault (files, dirs, symlinks as symlinks). |
| `dump --vault DIR --password PW` | Prints `{"entries":[…]}` on stdout, sorted by NFC path: `{"path","type":"file","size","sha256"}`, `{"path","type":"dir"}`, `{"path","type":"symlink","target"}`. |
| `write --vault DIR --password PW --source SRC` | Opens an existing vault (any scrypt N, extra `foldersafe/` dir is fine) and copies `SRC` into it, overwriting files. |
| `selftest` | Generates a tree (empty / 1 B / 32768 B / 100000 B files, 3-level dirs, CJK+emoji name, NFD name, 200- and 310-char names → `.c9s`, symlinks), runs create → dump → compare → write → dump → compare, prints `OK`. |

| `verify-vectors --file F` | Cross-checks the L1 sections of `docs/spec/test-vectors/v1.json` (keys, scrypt, aesSiv, masterkeyFile, vaultConfig, dirPaths, names, fileContent) against cryptolib/cryptofs APIs. One `✓`/`✗` line per check; exit 1 on any mismatch. File contents are rebuilt with cryptolib's own v2 header/content cryptors (package-private constructors, fed the vector's nonces and content key) and decrypted through the public `Cryptor` API. |

Exit code 0 on success, 1 on failure, 2 on bad usage. Only `dump` (JSON), `selftest` (`OK`) and `verify-vectors` write to stdout;
library log output (slf4j-simple), cryptofs filesystem events and the harness's own notes go to stderr.

`dump` additionally reports on stderr: vault-root entries cryptofs does not use (e.g. `foldersafe/`), non-NFC names,
and a mismatch between the number of ciphertext nodes on disk and the entries cryptofs listed (= nodes it could not
decrypt or silently skipped).

## Caveats

- `dump` opens the vault read-only, but cryptofs still touches the disk: every open writes
  `vault.cryptomator.<8 HEX>.bkup` if missing, and directory listings rename/delete sync-conflict copies
  (`… (1).c9r`) — exactly what the Cryptomator app does.
- Symlink targets pass through `java.nio` paths, so `//` and a trailing `/` in a target are collapsed and the target is
  NFC-normalised.
- `JAVA_HOME_22` overrides the JDK used by `run.sh`; `INTEROP_DEBUG=1` prints stack traces.
