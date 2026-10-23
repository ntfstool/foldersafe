import Foundation
import FSKit
import os
import FolderSafeCore

let fsLog = Logger(subsystem: "app.foldersafe.mac.fskit", category: "fs")

/// 扩展里所有失败都以 POSIX 错误码交给 FSKit（终端、Finder 看到的就是 ENOENT / EEXIST 之类）。
struct POSIXFailure: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}

func fsError(_ code: Int32) -> Error { fs_errorForPOSIXError(code) }

/// 任意错误 → FSKit 认识的 POSIX 错误。
func fsError(_ error: Error) -> Error {
    fs_errorForPOSIXError(posixCode(error))
}

func posixCode(_ error: Error) -> Int32 {
    if let p = error as? POSIXFailure { return p.code }
    if let v = error as? VaultError {
        // 内核自己的 posixCode 把错密码之类算成 EACCES；在挂载层这些都不该出现
        return v.posixCode
    }
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
    if ns.domain == NSCocoaErrorDomain {
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return ENOENT
        case NSFileWriteFileExistsError: return EEXIST
        case NSFileWriteOutOfSpaceError: return ENOSPC
        case NSFileWriteVolumeReadOnlyError: return EROFS
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return EACCES
        default: break
        }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain { return Int32(u.code) }
    }
    return EIO
}
