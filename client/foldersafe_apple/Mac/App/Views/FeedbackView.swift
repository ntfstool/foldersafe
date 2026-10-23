import SwiftUI
import AppKit

enum Feedback {
    static var mailto: URL {
        AppInfo.mailtoURL(subject: String(localized: "FolderSafe feedback"),
                          body: "\n\n—\nFolderSafe \(AppInfo.version) (\(AppInfo.build)), macOS \(AppInfo.osVersion)")
    }
}

