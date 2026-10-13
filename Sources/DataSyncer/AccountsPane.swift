// Settings → Accounts: what this Mac already has for SSH (read from ~/.ssh, never changed), and the sign-ins
// Data Syncer keeps in the Keychain for its destinations.
import SwiftUI
import DataSyncerCore

struct AccountsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var ssh: SSHOverview?
    @State private var saved: [(account: String, label: String)] = []
    @State private var loadError: String?
    @State private var adding: CloudProvider?
    @State private var signingOut: CloudAccount?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("SSH on this Mac").fontWeight(.semibold)
                    Spacer()
                    Button("Open ~/.ssh in Finder") { NSWorkspace.shared.activateFileViewerSelecting([SSHInfo.sshDir]) }.buttonStyle(.link).foregroundStyle(Theme.accent).font(.system(size: 12))
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Look again")
                }
                if let ssh {
                    LabeledContent("Keys in ~/.ssh") {
                        if ssh.keys.isEmpty { Text("none found").foregroundStyle(.secondary) }
                        else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(ssh.keys) { k in
                                    HStack(spacing: 6) {
                                        Text(k.name).font(.system(size: 12.5, design: .monospaced))
                                        Text([k.type, k.comment].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary)
                                        if !k.hasPublicHalf { Text("no .pub file").font(.system(size: 11)).foregroundStyle(Theme.attention) }
                                    }
                                }
                            }
                        }
                    }
                    LabeledContent("Loaded in ssh-agent") {
                        if let a = ssh.agentKeys { a.isEmpty ? Text("none").foregroundStyle(.secondary) : Text(a.joined(separator: "\n")).font(.system(size: 12, design: .monospaced)) }
                        else { Text("no agent reachable").foregroundStyle(.secondary) }
                    }
                    LabeledContent("Hosts in ~/.ssh/config") {
                        if ssh.configHosts.isEmpty { Text("none").foregroundStyle(.secondary) }
                        else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(ssh.configHosts) { h in
                                    Text("\(h.alias)  →  \(h.user.map { "\($0)@" } ?? "")\(h.hostName ?? h.alias)\(h.port.map { ":\($0)" } ?? "")\(h.identityFile.map { "  key \($0)" } ?? "")")
                                        .font(.system(size: 12, design: .monospaced))
                                }
                            }
                        }
                    }
                    LabeledContent("Known servers") { Text("\(ssh.knownHostsCount) in ~/.ssh/known_hosts") }
                    Text("An SSH destination can use these as Terminal does (keys in the agent, config entries, default keys), a chosen key file, or a password. Data Syncer only reads this folder.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…").foregroundStyle(.secondary) }
                }
            }
            Section {
                Text("Sign-ins in the Keychain").fontWeight(.semibold)
                if let loadError { Text(loadError).foregroundStyle(Theme.problem).font(.system(size: 12.5)) }
                if saved.isEmpty {
                    Text("None yet. A network share's password, an SSH password or key passphrase, or a cloud sign-in is saved here when you add that destination.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                ForEach(saved, id: \.account) { item in
                    HStack {
                        Text(item.label)
                        Spacer()
                        Button("Forget") { forget(item.account) }.font(.system(size: 12))
                    }
                }
                Text("The secrets themselves live in your Mac's Keychain (Keychain Access shows them under “Data Syncer”). Forgetting one means the destination asks for it again — or, for a share that Finder has already connected, keeps working.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Cloud accounts").fontWeight(.semibold)
                    Spacer()
                    Menu("Add account…") {
                        ForEach(CloudProvider.allCases, id: \.self) { p in Button(p.label) { adding = p } }
                    }.frame(width: 140)
                }
                if model.cloudAccounts.isEmpty {
                    Text("None yet. Google Drive, Dropbox, OneDrive and Amazon S3 accounts are added here or when you add a destination of that kind; one account can serve many destinations.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                ForEach(model.cloudAccounts) { a in
                    HStack {
                        Image(systemName: a.provider == .s3 ? "shippingbox" : "cloud").frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(a.provider.label) — \(a.label)")
                            Text(uses(a)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign out") { signingOut = a }.font(.system(size: 12))
                            .help("Forgets the account and its tokens; destinations that use it will ask for an account")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await load()
            // development only: DATASYNCER_AUTOSHEET=settings:accounts:<provider> opens the add-account sheet
            if let p = ProcessInfo.processInfo.environment["DATASYNCER_AUTOSHEET"]?.split(separator: ":").dropFirst(2).first.flatMap({ CloudProvider(rawValue: String($0)) }) { adding = p }
        }
        .sheet(item: $adding) { p in CloudAccountSheet(provider: p) { _ in } }
        .confirmationDialog("Sign out of \(signingOut?.provider.label ?? "") (\(signingOut?.label ?? ""))?", isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }), titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { if let a = signingOut { model.remove(a) }; signingOut = nil }
            Button("Cancel", role: .cancel) { signingOut = nil }
        } message: {
            Text(signingOut.map { "\(uses($0).prefix(1).uppercased() + uses($0).dropFirst()). The sign-in is forgotten; nothing in the service is touched." } ?? "")
        }
    }

    private func uses(_ a: CloudAccount) -> String {
        let n = model.jobs.flatMap(\.destinations).filter { $0.kind.cloudAccount == a.id.uuidString }.count
        return n == 0 ? "not used by any destination yet" : "used by \(n) destination\(n == 1 ? "" : "s")"
    }

    private func load() async {
        ssh = await SSHInfo.overview()
        do {
            let accounts = try model.secrets.accounts()
            saved = accounts.filter { SecretAccount.cloudId($0) == nil }.map { a in
                if let id = SecretAccount.destinationId(a) {
                    for job in model.jobs { if let d = job.destinations.first(where: { $0.id == id }) { return (a, "\(d.name) — \(d.kind.label) (job “\(job.name)”)") } }
                    return (a, "a destination that no longer exists")
                }
                return (a, a)
            }
        } catch let e as DSError { loadError = e.message } catch { loadError = error.localizedDescription }
    }

    private func forget(_ account: String) {
        do { try model.secrets.remove(for: account) } catch { model.notice = Notice(title: "Could not forget the sign-in", message: error.localizedDescription) }
        Task { await load() }
    }
}
