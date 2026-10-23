import SwiftUI
import AppKit

// MARK: - Vault 图标

struct VaultGlyph: View {
    let unlocked: Bool
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: unlocked ? [Color.orange.opacity(0.95), Color.orange.opacity(0.75)]
                                                      : [Color.fsAccent, Color.fsAccent.opacity(0.78)],
                                     startPoint: .top, endPoint: .bottom))
            Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: unlocked ? size * 0.04 : 0)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.12), radius: size * 0.05, y: size * 0.03)
        .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let unlocked: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(unlocked ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text(unlocked ? "Unlocked" : "Locked")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - 提示框

struct Callout: View {
    enum Style { case info, warning, success }
    let style: Style
    let text: Text
    var systemImage: String?

    init(_ style: Style, _ text: Text, systemImage: String? = nil) {
        self.style = style
        self.text = text
        self.systemImage = systemImage
    }

    private var color: Color {
        switch style {
        case .info: return .fsAccent
        case .warning: return .orange
        case .success: return .green
        }
    }
    private var icon: String {
        systemImage ?? {
            switch style {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            text.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.25)))
    }
}

struct ErrorLine: View {
    let message: String?
    var body: some View {
        if let message, !message.isEmpty {
            Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.callout)
            .foregroundStyle(.red)
            .transition(.opacity)
        }
    }
}

// MARK: - 密码强度

enum PasswordRules {
    static let minLength = 8

    static func isAcceptable(_ p: String) -> Bool {
        p.count >= minLength && !p.contains(where: \.isNewline) && !p.contains("\0")
    }

    /// 0…4：粗略估计，只做提示，不拦截（≥8 位即可）。
    static func score(_ p: String) -> Int {
        guard !p.isEmpty else { return 0 }
        var classes = 0
        if p.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if p.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if p.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if p.rangeOfCharacter(from: CharacterSet.alphanumerics.union(.whitespaces).inverted) != nil { classes += 1 }
        let unique = Set(p).count
        if p.count < minLength { return 1 }
        var s = 1
        if p.count >= 12 { s += 1 }
        if p.count >= 16 { s += 1 }
        if classes >= 3 { s += 1 }
        if p.count >= 20 && classes >= 2 { s += 1 }
        if unique < 5 { s = 1 }
        return min(s, 4)
    }
}

struct StrengthMeter: View {
    let password: String

    var body: some View {
        let s = PasswordRules.score(password)
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(i < s ? color(s) : Color.primary.opacity(0.1)).frame(height: 5)
                }
            }
            .frame(width: 160)
            Text(label(s)).font(.caption).foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.15), value: s)
        .accessibilityElement(children: .combine)
    }

    private func color(_ s: Int) -> Color { s <= 1 ? .red : s == 2 ? .orange : s == 3 ? .yellow : .green }
    private func label(_ s: Int) -> LocalizedStringKey {
        if password.isEmpty { return "At least 8 characters" }
        if password.count < PasswordRules.minLength { return "Too short" }
        switch s {
        case ...1: return "Weak"
        case 2: return "Fair"
        case 3: return "Good"
        default: return "Strong"
        }
    }
}

/// 新密码 + 确认 + 强度。
struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirm: String
    var newLabel: LocalizedStringKey = "Password"
    var confirmLabel: LocalizedStringKey = "Confirm password"

    var mismatch: Bool { !confirm.isEmpty && confirm != password }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(newLabel, text: $password)
                .textFieldStyle(.roundedBorder)
            StrengthMeter(password: password)
            SecureField(confirmLabel, text: $confirm)
                .textFieldStyle(.roundedBorder)
            if mismatch {
                Text("The passwords don’t match.").font(.caption).foregroundStyle(.red)
            }
        }
    }

    static func isValid(_ p: String, _ c: String) -> Bool { PasswordRules.isAcceptable(p) && p == c }
}

// MARK: - 找回短语

struct PhraseGrid: View {
    let words: [String]
    var redacted = false

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(.caption, design: .rounded).monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    Text(redacted ? "••••••" : w)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

enum PhraseExport {
    /// 存成文本文件前先警告：文本文件本机任何程序都能读。
    @MainActor
    static func saveAsText(words: [String], vaultName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Save the recovery phrase as a text file?")
        alert.informativeText = String(localized: "Any app on this Mac — including AI tools — can read an unencrypted text file, and so can anyone who gets the file. Paper is safer. If you save it, keep it somewhere private (for example, a USB drive you store away) and never inside this vault.")
        alert.addButton(withTitle: String(localized: "Save Anyway…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "\(vaultName) recovery phrase.txt")
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let numbered = words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let text = String(localized: "FolderSafe recovery phrase for “\(vaultName)”") + "\n\n" + numbered + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 抽查 3 个词。
struct PhraseQuiz: View {
    let words: [String]
    let indices: [Int]
    @Binding var answers: [String]

    static func pick() -> [Int] { Array((0..<12).shuffled().prefix(3)).sorted() }

    static func matches(_ answer: String, _ word: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == word
    }

    var allCorrect: Bool {
        indices.indices.allSatisfy { i in i < answers.count && PhraseQuiz.matches(answers[i], words[indices[i]]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(indices.enumerated()), id: \.offset) { i, wordIndex in
                HStack(spacing: 12) {
                    Text("Word \(wordIndex + 1)")
                        .frame(width: 90, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField("", text: $answers[i])
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .frame(width: 220)
                    let a = answers[i].trimmingCharacters(in: .whitespaces)
                    Image(systemName: PhraseQuiz.matches(a, words[wordIndex]) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(PhraseQuiz.matches(a, words[wordIndex]) ? Color.green : Color.secondary.opacity(0.4))
                        .imageScale(.large)
                }
            }
        }
    }
}

// MARK: - 找回短语输入

struct PhraseInput: View {
    @Binding var text: String

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 84)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Text("Separate the words with spaces. The first four letters of each word are enough.")
                Spacer()
                Text("\(wordCount)/12").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 表单/弹窗骨架

struct SheetHeader: View {
    let title: LocalizedStringKey
    var subtitle: Text?
    var systemImage: String?
    var unlockedGlyph: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let unlockedGlyph {
                VaultGlyph(unlocked: unlockedGlyph, size: 44)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.fsAccent)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    subtitle.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 进行中的按钮：转圈 + 文字。
struct WorkingLabel: View {
    let title: LocalizedStringKey
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
    }
}
