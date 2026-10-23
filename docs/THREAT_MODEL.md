# FolderSafe threat model

This document describes what FolderSafe protects, against whom, and where the limits are. It covers the vault format
(`docs/spec/vault-format-v1.md`) and the Apple apps in this repository (macOS app, iPhone app, File Provider extension;
the FSKit extension is built but hidden in 1.0). The format's own analysis is in spec §9.

## Assets

- File and folder names, file contents and symlink targets inside a vault.
- The vault keys: `rawKey = encKey || macKey` (2 × 256 bit), generated once per vault and never changed.
- The secrets that unlock `rawKey`: the password, the 12-word recovery phrase, and per-device biometric keys.

## Adversaries

| Adversary | Examples |
|---|---|
| Ciphertext holder | Cloud sync provider, backup host, someone who copies the vault folder or steals a powered-off disk. |
| Other local users and administrators | Another account on the Mac, an admin using `sudo` / root, IT tooling. |
| Programs running as you | AI agents and coding tools with disk access, indexers, malware running under your account. |
| Online attacker | There is no FolderSafe server or account to attack (see "No server" below). |

## While a vault is locked

Protected against all adversaries above:

- Names, contents, symlink targets and the directory hierarchy are encrypted (AES-SIV for names and directory IDs,
  AES-GCM per 32 KiB chunk for contents — Cryptomator vault format 8, `SIV_GCM`).
- No key material is stored in plaintext. `rawKey` exists on disk only in wrapped form:
  - `masterkey.cryptomator`: wrapped with a key derived from the password by **scrypt** (N = 32768, r = 8, p = 1,
    32-byte salt), the same parameters Cryptomator uses by default so mobile clients can open the vault;
  - `foldersafe/recovery.json`: wrapped with AES-GCM under a key derived by HKDF from the 128-bit recovery phrase entropy
    (no slow KDF needed at 128 bits), bound to the vault ID;
  - device keys (Touch ID / Face ID, spec §7.4): a data-protection keychain item on that device only, access control
    `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `biometryCurrentSet`. It never leaves the device, is not synced,
    becomes unusable when the enrolled fingerprints / faces change, and reading it requires Touch ID / Face ID.
    It is never stored in the vault.
- The File Provider item index (which maps system item IDs to cleartext names) is encrypted with a key derived from the
  vault key, so it reveals nothing without the key.
- On macOS, leftover unlock keys from a crash are deleted when the app starts, and leftover Finder locations are removed.

Not protected while locked:

- **Metadata** (spec §9): number of files and folders, each file's size (±28 bytes per 32 KiB), modification times,
  which files change and when, the vault ID and the scrypt parameters.
- **The list of your vaults on this device**: display names, folder paths and security-scoped bookmarks are kept in
  the app's App Group container (no keys). Local administrators can read this list.
- **Offline password guessing** against `masterkey.cryptomator`: scrypt slows it down, it cannot stop it. Use a strong
  password. The recovery phrase is not guessable (128 bits) but is a second master key — store it like a password.
- **Tampering / rollback**: someone with write access to the ciphertext can delete files, restore older ciphertext
  files or swap whole files between versions; content chunks are authenticated, but the format does not detect rollback
  of a whole file to an earlier valid version.

## While a vault is unlocked

By design, the cleartext is available to **any process running as you**: that is what makes it a usable folder.
This includes AI tools and malware under your account. FolderSafe limits the time window instead:

- Automatic locking on sleep, screen lock, idle timeout and app quit (macOS); an auto-lock timeout on iPhone, enforced by
  the extension itself even if the app is not running.
- While unlocked, `rawKey` is held in the extension's memory and in a shared keychain item
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronised, readable only by apps of the same developer team)
  so the extension can open the vault. Locking deletes the item, and the extension drops its in-memory key.
- A root-level attacker on a running, unlocked machine can read process memory and the plaintext; FolderSafe does not
  defend against that.

### File Provider cache (macOS and iPhone)

Unlocked vaults appear as File Provider locations (Finder sidebar on macOS, Files app on iPhone). The system keeps
**cleartext copies of files that were opened or copied in** while the vault is unlocked:

- macOS: `~/Library/CloudStorage/<App name>-<vault name>/`;
- iPhone: the extension's File Provider storage inside the App Group container.

When a vault is locked, FolderSafe first waits until every change has been written back into the vault, then removes the
location, and the system deletes these copies. Edge cases:

- Forced lock (auto-lock, quit) while changes are still being written back: on macOS the location is removed and the
  not-yet-saved files are **kept in cleartext** at the old location; the app tells you where, so you can copy them back
  into the vault and delete them. On iPhone the system cannot keep them separately, so the location stays registered but
  the key is deleted and the extension refuses all access; the pending changes are written back on the next unlock.
- Deleted copies are removed with normal file-system deletion, not secure erasure. On SSDs with FileVault / iPhone data
  protection this is the platform's guarantee, not FolderSafe's.

## No server

FolderSafe has no accounts and no server-side component. Passwords, recovery phrases and keys never leave your device;
there is nothing for the FolderSafe project to hand over, reset or recover. The open-source edition contains no network
code at all (only links to the website and `mailto:` addresses).

## Out of scope

- Malware or a compromised OS on a device where the vault is unlocked.
- Loss of both the password and the recovery phrase (data cannot be recovered).
- Deleting or corrupting the vault folder: encryption is not a backup.
- Side channels on shared hardware, cold-boot attacks, and coercion.
- Hiding the existence of a vault (no plausible deniability).
