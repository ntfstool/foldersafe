import Foundation
import Security
import FolderSafeCore

/// 把内核 / 钥匙串的错误翻成给人看的话。
enum ErrorText {
    /// 用户在 Face ID 弹窗里点了取消：不提示。
    static func isCancellation(_ error: Error) -> Bool {
        if case DeviceKeyStore.Failure.cancelled = error { return true }
        if case AppError.filesLocationDisabled = error { return true }      // 由 RootView 单独提示
        if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSUserCancelledError { return true }
        return false
    }

    static func message(for error: Error) -> String {
        switch error {
        case VaultError.wrongPassword:
            return String(localized: "The password is incorrect.")
        case VaultError.wrongRecoveryPhrase:
            return String(localized: "This recovery phrase doesn't belong to this vault.")
        case VaultError.invalidRecoveryPhrase:
            return String(localized: "That isn't a valid recovery phrase. Check that all 12 words are spelled correctly and in the right order.")
        case VaultError.unsupported(let detail) where detail.contains("recovery"):
            return String(localized: "This vault doesn't have a recovery phrase yet. Unlock it with your password, then create one in Vault Settings.")
        case VaultError.unsupported:
            return String(localized: "This vault uses a format that FolderSafe doesn't support.")
        case VaultError.readOnly:
            return String(localized: "This vault was changed by a newer app and can only be read here. Update FolderSafe to make changes.")
        case VaultError.notFound, VaultError.notADirectory:
            return String(localized: "The vault folder can't be found. It may have been moved, renamed or deleted, or its storage location isn't available right now.")
        case VaultError.alreadyExists:
            return String(localized: "A folder with this name already exists and isn't empty. Choose a different name.")
        case VaultError.invalidPassword:
            return String(localized: "Use at least 8 characters, without line breaks.")
        case VaultError.corrupted:
            return String(localized: "Some of the vault's files look damaged or incomplete. If the vault is in iCloud Drive, wait until it has finished downloading and try again.")
        case VaultError.invalidName:
            return String(localized: "This name can't be used.")
        case DeviceKeyStore.Failure.unavailable:
            return String(localized: "Face ID isn't available. Check that Face ID and a passcode are set up on this iPhone.")
        case DeviceKeyStore.Failure.keychain:
            return String(localized: "Face ID unlock isn't available for this vault right now. Unlock with your password.")
        case FileProviderPresenter.Failure.unsyncedChanges:
            return String(localized: "Some changes from the Files app haven't been saved into the vault yet. Try again in a moment.")
        case FileProviderPresenter.Failure.noUserVisibleURL:
            return String(localized: "The vault couldn't be added to the Files app. Try again, or restart your iPhone if this keeps happening.")
        case let e as LocalizedError where e.errorDescription != nil:
            return e.errorDescription!
        default:
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) {
                return String(localized: "FolderSafe doesn't have permission to use this folder anymore. Remove the vault from the list and add it again.")
            }
            return error.localizedDescription
        }
    }
}
