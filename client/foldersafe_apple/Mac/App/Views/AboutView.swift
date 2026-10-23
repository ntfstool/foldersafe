import SwiftUI
import AppKit

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("FolderSafe").font(.title.weight(.semibold))
                Text("Version \(AppInfo.version) (\(AppInfo.build))")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("An encrypted folder for the AI era.")
                .font(.callout)
            HStack(spacing: 16) {
                Link("Website", destination: AppInfo.website)
                Link("Privacy Policy", destination: AppInfo.privacyURL)
                Link("Terms of Use", destination: AppInfo.termsURL)
                Link(AppInfo.supportEmail, destination: AppInfo.mailtoURL(subject: "FolderSafe \(AppInfo.version)"))
            }
            .font(.callout)
            Text("Vaults use an open, documented format compatible with Cryptomator vault format 8, so your files aren’t tied to this app. FolderSafe is independent and not affiliated with Cryptomator.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            Text("© 2026 FolderSafe")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
