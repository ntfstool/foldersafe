import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var addError: String?

    var body: some View {
        NavigationStack(path: $model.path) {
            VaultListView()
                .navigationDestination(for: String.self) { id in
                    VaultDetailView(vaultId: id)
                }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newVault:
                NewVaultWizard(startAt: model.snapshot == .wizardPhrase ? .phrase : (model.snapshot == .wizardLocation ? .location : .name))
                    .interactiveDismissDisabled()
            case .addExisting:
                FolderPicker { url in
                    model.sheet = nil
                    Task {
                        do {
                            let r = try await model.addExisting(url)
                            model.path = [r.id]
                        } catch {
                            addError = ErrorText.message(for: error)
                        }
                    }
                } onCancel: {
                    model.sheet = nil
                }
                .ignoresSafeArea()
            case .settings:
                SettingsView()
            }
        }
        .errorAlert($addError)
        .errorAlert($model.alertMessage)
        .alert("Turn on FolderSafe in the Files app", isPresented: Binding(get: { model.filesDisabledVault != nil },
                                                                          set: { if !$0 { model.filesDisabledVault = nil } }),
               presenting: model.filesDisabledVault) { _ in
            Button("Open Files App") { FilesApp.open(nil) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("The vault is ready, but its location is switched off in Files. In the Files app, tap Browse, tap the More button (…) at the top, choose Edit, and turn on “\(r.name)”. Then come back and unlock again.")
        }
        .alert("Changes are still being saved", isPresented: Binding(get: { model.lockFailure != nil },
                                                                    set: { if !$0 { model.lockFailure = nil } }),
               presenting: model.lockFailure) { r in
            Button("Lock Now") {
                Task { try? await model.lock(r, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Some changes from the Files app haven't been saved into the vault yet. Wait a moment and try again, or lock now: the remaining changes will be saved the next time you unlock this vault.")
        }
        .tint(Color.brand)
        .task {
            applySnapshot()
        }
    }

    private func applySnapshot() {
        switch model.snapshot {
        case .wizardPhrase, .wizardLocation: model.sheet = .newVault
        case .settings: model.sheet = .settings
        case .unlock: model.path = ["demo-tax"]
        case .unlocked: model.path = ["demo-tax"]
        default: break
        }
    }
}

struct VaultListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.records.isEmpty {
                EmptyVaultsView()
            } else {
                list
            }
        }
        .navigationTitle("FolderSafe")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { model.sheet = .settings } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("Settings"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { model.sheet = .newVault } label: {
                        Label("New Vault", systemImage: "plus.rectangle.on.folder")
                    }
                    Button { model.sheet = .addExisting } label: {
                        Label("Add Existing Vault", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Add Vault"))
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.records) { r in
                    NavigationLink(value: r.id) {
                        VaultRow(record: r)
                    }
                    .swipeActions(edge: .trailing) {
                        if model.isUnlocked(r) {
                            Button {
                                Task { await model.userLock(r) }
                            } label: {
                                Label("Lock", systemImage: "lock.fill")
                            }
                            .tint(Color.brand)
                        }
                    }
                }
            } footer: {
                Text("Unlocked vaults appear in the Files app under Browse › Locations. Locked vaults are only encrypted data.")
            }

            if model.anyUnlocked {
                Section {
                    Button {
                        Task { await model.lockAll(force: false) }
                    } label: {
                        Label("Lock All Vaults", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct VaultRow: View {
    @EnvironmentObject private var model: AppModel
    var record: VaultRecord

    var body: some View {
        let unlocked = model.isUnlocked(record)
        HStack(spacing: 14) {
            VaultIcon(unlocked: unlocked, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.headline)
                        .lineLimit(1)
                    if model.biometricsEnabled(record) {
                        Image(systemName: model.biometrySymbol)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("\(model.biometryName) on"))
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: record.path.contains("Mobile Documents") ? "icloud" : "folder")
                        .imageScale(.small)
                    Text(record.locationHint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            StatusBadge(unlocked: unlocked)
                .fixedSize()
        }
        .padding(.vertical, 6)
    }
}

struct EmptyVaultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(Color.brand.opacity(0.12))
                        .frame(width: 128, height: 128)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 58, weight: .regular))
                        .foregroundStyle(Color.brand.gradient)
                }
                .padding(.top, 48)
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("Lock files away from AI agents and prying eyes")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("A vault is an encrypted folder. While it's locked, AI agents, other apps and administrators can't read what's inside. When you unlock it, it appears in the Files app.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)

                VStack(spacing: 12) {
                    Button { model.sheet = .newVault } label: {
                        Label("Create a Vault", systemImage: "plus")
                    }
                    .buttonStyle(WideButtonStyle())
                    Button { model.sheet = .addExisting } label: {
                        Label("Add Existing Vault", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(WideButtonStyle(prominent: false))
                }
                .padding(.top, 8)

                Text("Free, no account. Your password never leaves this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }
}
