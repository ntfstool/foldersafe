import Foundation
import Security
import FolderSafeCore

/// 把内核 / 钥匙串错误翻译成用户看得懂的话。返回 nil 表示用户自己取消了，不用提示。
enum ErrorText {
    static func describe(_ error: Error) -> String? {
        if let e = error as? VaultError { return vault(e) }
        if let e = error as? DeviceKeyStore.Failure {
            switch e {
            case .cancelled: return nil
            case .unavailable: return String(localized: "Touch ID isn’t available on this Mac right now.")
            case .keychain(let status):
                if status == errSecItemNotFound {
                    return String(localized: "Touch ID is no longer set up for this vault (for example, after fingerprints changed). Unlock with your password, then turn Touch ID on again.")
                }
                return String(localized: "The Touch ID key couldn’t be read (keychain error \(Int(status))). Unlock with your password instead.")
            }
        }
        if let e = error as? UnlockedKeyStore.Failure, case .keychain(let status) = e {
            return String(localized: "FolderSafe couldn’t hand the key to the system (keychain error \(Int(status))). The vault is still locked.")
        }
        if let e = error as? FileProviderPresenter.Failure {
            switch e {
            case .unsyncedChanges:
                return String(localized: "Some changes haven’t been saved into the vault yet. Wait a moment and try again.")
            case .unsavedChangesPreserved(let url):
                return String(localized: "Locked. Some changes couldn’t be written into the vault in time and were kept at \(url.path). Move them back into the vault, then delete them.")
            case .noUserVisibleURL:
                return String(localized: "macOS didn’t provide a location for this vault. Please try again.")
            case .vaultNotAccessible:
                return String(localized: "FolderSafe couldn’t give its Finder extension access to the vault folder. Remove the vault from FolderSafe, add its folder again, then unlock.")
            case .vaultLocationNotSupported(let path):
                return String(localized: "FolderSafe can’t open vaults stored at \(path.abbreviatingHome) in Finder. Move the vault folder into your home folder or onto an external drive, add it to FolderSafe again, then unlock.")
            case .extensionUnavailable:
                return String(localized: "macOS couldn’t start FolderSafe’s Finder extension. Make sure only one copy of FolderSafe is installed (in Applications), quit FolderSafe, open it again, then unlock.")
            case .disabledByUser:
                return String(localized: "Turn on FolderSafe in System Settings › General › Login Items & Extensions › File Providers, then click Try Again.")
            }
        }
        #if !APPSTORE
        if let e = error as? FSKitPresenter.Failure {
            switch e {
            case .unsupportedSystem:
                return String(localized: "Opening vaults as real folders requires macOS 26 or later.")
            case .moduleDisabled:
                return String(localized: "Turn on FolderSafe in System Settings › General › Login Items & Extensions › File System Extensions, then try again.")
            case .vaultNotFound:
                return String(localized: "The vault folder can’t be found. It may have been moved or renamed, or it’s on a drive that isn’t connected.")
            case .mountPointNotEmpty(let p):
                return String(localized: "The folder \(p.abbreviatingHome) isn’t empty, so the vault can’t open there. Choose another folder under “Opens at”.")
            case .mountPointInUse(let p):
                return String(localized: "Something else is already open at \(p.abbreviatingHome).")
            case .mountFailed(let m):
                return String(localized: "The vault couldn’t be opened as a folder: \(m)")
            case .busy(let apps):
                return String(localized: "The vault is in use by: \(apps.joined(separator: ", "))")
            case .unmountFailed(let m):
                return String(localized: "The vault folder couldn’t be closed: \(m)")
            }
        }
        #endif
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSUserCancelledError) { return nil }
        if ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) {
            return String(localized: "The vault folder can’t be found. It may have been moved or renamed, or it’s on a drive that isn’t connected.")
        }
        if ns.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
            return String(localized: "FolderSafe doesn’t have permission to access this folder.")
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
            return String(localized: "There isn’t enough free space on the disk.")
        }
        return ns.localizedDescription
    }

    static func vault(_ e: VaultError) -> String {
        switch e {
        case .wrongPassword:
            return String(localized: "Incorrect password.")
        case .wrongRecoveryPhrase:
            return String(localized: "This recovery phrase doesn’t belong to this vault, or it’s an older phrase that has been replaced.")
        case .invalidRecoveryPhrase:
            return String(localized: "That isn’t a valid recovery phrase. Check that all 12 words are spelled correctly and in the right order.")
        case .corrupted:
            return String(localized: "The vault’s key files appear to be damaged or incomplete (for example, still syncing). FolderSafe hasn’t changed anything.")
        case .unsupported(let detail):
            if detail.contains("recovery") {
                return String(localized: "This vault has no recovery phrase. Unlock it with its password.")
            }
            return String(localized: "This vault uses a format or option FolderSafe doesn’t support (\(detail)).")
        case .readOnly:
            return String(localized: "This vault uses features this version of FolderSafe doesn’t know yet, so it can’t be changed. Please update FolderSafe.")
        case .notFound:
            return String(localized: "The vault folder can’t be found. It may have been moved or renamed, or it’s on a drive that isn’t connected.")
        case .alreadyExists:
            return String(localized: "That folder already exists and isn’t empty. Choose another name or location.")
        case .notADirectory:
            return String(localized: "That location isn’t a folder.")
        case .invalidName:
            return String(localized: "That name can’t be used.")
        case .invalidPassword:
            return String(localized: "The password must have at least 8 characters and no line breaks.")
        default:
            // 读写层的错误（磁盘、权限等）：附上内核给的说明
            return String(localized: "A disk error occurred (\(String(describing: e))).")
        }
    }
}
