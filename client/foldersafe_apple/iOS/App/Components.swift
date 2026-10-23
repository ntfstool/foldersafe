import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MessageUI

// MARK: - 图标与状态

/// vault 的圆角图标：上锁是蓝色锁，解锁是绿色开锁。
struct VaultIcon: View {
    var unlocked: Bool
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(unlocked ? Color.green.gradient : Color.brand.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    var unlocked: Bool

    var body: some View {
        Text(unlocked ? "Unlocked" : "Locked")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(unlocked ? Color.green : Color.secondary)
            .background((unlocked ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
    }
}

/// 黄色提示框：重要但不吓人的提醒。
struct Notice: View {
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 密码

enum PasswordStrength: Int, CaseIterable {
    case tooShort, weak, fair, good, strong

    static let common: Set<String> = ["password", "password1", "12345678", "123456789", "1234567890", "qwertyui",
                                      "qwerty123", "iloveyou", "11111111", "00000000", "abcd1234", "88888888",
                                      "a1234567", "abc12345", "password123", "letmein1", "welcome1", "admin123"]

    static func evaluate(_ p: String) -> PasswordStrength {
        guard p.count >= 8 else { return .tooShort }
        if common.contains(p.lowercased()) || Set(p).count <= 3 { return .weak }
        var classes = 0
        if p.contains(where: \.isLowercase) { classes += 1 }
        if p.contains(where: \.isUppercase) { classes += 1 }
        if p.contains(where: \.isNumber) { classes += 1 }
        if p.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        var score = classes - 1
        if p.count >= 12 { score += 1 }
        if p.count >= 16 { score += 1 }
        if p.count >= 20 { score += 1 }
        switch score {
        case ..<1: return .weak
        case 1: return .fair
        case 2: return .good
        default: return .strong
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .tooShort: return "At least 8 characters"
        case .weak: return "Weak"
        case .fair: return "Fair"
        case .good: return "Good"
        case .strong: return "Strong"
        }
    }

    var color: Color {
        switch self {
        case .tooShort: return .secondary
        case .weak: return .red
        case .fair: return .orange
        case .good: return .yellow
        case .strong: return .green
        }
    }
}

struct StrengthMeter: View {
    var password: String

    var body: some View {
        let s = PasswordStrength.evaluate(password)
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(1..<5) { i in
                    Capsule()
                        .fill(i <= s.rawValue ? s.color : Color(.systemFill))
                        .frame(height: 5)
                }
            }
            .frame(maxWidth: 140)
            Text(s.label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(s == .tooShort ? Color.secondary : s.color)
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.2), value: s)
        .accessibilityElement(children: .combine)
    }
}

/// 新密码 + 确认 + 强度条。合格（≥8 位且两次一致）时 isValid 为 true。
struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirm: String
    var newLabel: LocalizedStringKey = "Password"

    static func isValid(_ p: String, _ c: String) -> Bool {
        p.count >= 8 && p == c && !p.contains(where: \.isNewline)
    }

    var body: some View {
        SecureField(newLabel, text: $password)
            .textContentType(.newPassword)
        SecureField("Confirm Password", text: $confirm)
            .textContentType(.newPassword)
        StrengthMeter(password: password)
        if !confirm.isEmpty && confirm != password {
            Label("Passwords don't match", systemImage: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - 找回短语

struct PhraseGrid: View {
    var words: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 8) {
                    Text(verbatim: "\(i + 1)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                    Text(w)
                        .font(.body.monospaced().weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 大按钮

struct WideButtonStyle: ButtonStyle {
    var tint: Color = Color.brand
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(prominent ? Color.white : tint)
            .background(prominent ? tint : tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - 文件夹选择器

/// 系统的文件夹选择器：可以选"文件"App 能访问的任何位置（iCloud 云盘、我的 iPhone、其他存储服务）。
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker
        init(_ parent: FolderPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) } else { parent.onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onCancel() }
    }
}

// MARK: - 邮件

struct MailComposer: UIViewControllerRepresentable {
    var subject: String
    var body: String
    @Environment(\.dismiss) private var dismiss

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([SharedConfig.supportEmail])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}

// MARK: - 打开"文件"App

enum FilesApp {
    /// 打开"文件"App；能定位到 vault 根目录就直接定位，否则只打开 App。
    static func open(_ location: URL?) {
        let plain = URL(string: "shareddocuments://")!
        guard let location, let direct = FileProviderPresenter.filesAppURL(for: location), direct != plain else {
            UIApplication.shared.open(plain)
            return
        }
        UIApplication.shared.open(direct) { ok in
            if !ok { UIApplication.shared.open(plain) }
        }
    }
}

extension View {
    /// 统一的错误弹窗。
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Something went wrong", isPresented: Binding(get: { message.wrappedValue != nil },
                                                           set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

extension Color {
    /// 品牌蓝（Assets 里的 AccentColor，深色模式更亮）。
    static let brand = Color("AccentColor")
}
