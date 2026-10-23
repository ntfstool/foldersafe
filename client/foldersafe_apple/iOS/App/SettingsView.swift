import SwiftUI

/// App 设置与关于。本 App 不联网：链接都交给系统（Safari / 邮件）打开。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showMail = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(get: { model.autoLockEnabled }, set: { model.setAutoLock(enabled: $0) })) {
                        Label("Auto-Lock", systemImage: "lock.rotation")
                    }
                    if model.autoLockEnabled {
                        Picker(selection: Binding(get: { model.autoLockMinutes }, set: { model.setAutoLock(minutes: $0) })) {
                            ForEach(AutoLock.choices, id: \.self) { m in
                                Text("\(m) min").tag(m)
                            }
                        } label: {
                            Label("Lock After", systemImage: "timer")
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text(model.autoLockEnabled
                         ? "Unlocked vaults lock again \(model.autoLockMinutes) minutes after you unlock them or leave FolderSafe — also while FolderSafe is closed."
                         : "Vaults stay unlocked until you lock them. Turning on auto-lock is recommended.")
                }

                Section {
                    PrivacyRow(systemImage: "gift", title: "Free, no account",
                               text: "No sign-up, no ads, no in-app purchases.")
                    PrivacyRow(systemImage: "eye.slash", title: "No tracking",
                               text: "FolderSafe doesn't collect any data and doesn't connect to the internet.")
                    PrivacyRow(systemImage: "iphone", title: "Encrypted on this iPhone",
                               text: "Your password and keys never leave this device. Not even we can open your vaults.")
                } header: {
                    Text("Privacy")
                }

                Section {
                    Link(destination: URL(string: "https://foldersafe.app")!) {
                        Label("Website", systemImage: "globe")
                    }
                    Link(destination: URL(string: "https://foldersafe.app/privacy")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "https://foldersafe.app/terms")!) {
                        Label("Terms of Use", systemImage: "doc.plaintext")
                    }
                    Button {
                        if MailComposer.canSend { showMail = true } else { openURL(feedbackMailto) }
                    } label: {
                        Label("Send Feedback", systemImage: "envelope")
                    }
                } header: {
                    Text("Help")
                }

                Section {
                    PrivacyRow(systemImage: "doc.text.magnifyingglass", title: "Open format",
                               text: "Vaults are compatible with Cryptomator vault format 8, so your files aren't tied to this app. FolderSafe is independent and not affiliated with Cryptomator.")
                    PrivacyRow(systemImage: "exclamationmark.shield", title: "Know the limits",
                               text: "While a vault is unlocked, apps on this iPhone can read its files. Encryption isn't a backup. If you lose both your password and your recovery phrase, nobody can recover your files.")
                } header: {
                    Text("How It Works")
                }

                Section {
                    LabeledContent("Version", value: version)
                } footer: {
                    Text(verbatim: "© 2026 FolderSafe")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showMail) {
                MailComposer(subject: feedbackSubject, body: feedbackBody)
                    .ignoresSafeArea()
            }
        }
    }

    private var feedbackSubject: String { "FolderSafe iOS \(version)" }

    private var feedbackBody: String {
        "\n\n—\nFolderSafe \(version), iOS \(UIDevice.current.systemVersion)"
    }

    private var feedbackMailto: URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = SharedConfig.supportEmail
        c.queryItems = [URLQueryItem(name: "subject", value: feedbackSubject), URLQueryItem(name: "body", value: feedbackBody)]
        return c.url ?? URL(string: "mailto:\(SharedConfig.supportEmail)")!
    }
}

struct PrivacyRow: View {
    var systemImage: String
    var title: LocalizedStringKey
    var text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.brand)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
