// Adding a cloud account: the one-time setup guide for the service (owner decision 9: a high-level guide the
// first time, in the app), the fields it asks for, and the sign-in — the browser opens, the service sends the
// user back, and the account is saved with its tokens in the Keychain.
import SwiftUI
import DataSyncerCore

struct CloudAccountSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let provider: CloudProvider
    /// called with the new account once it is saved
    var onAdded: (CloudAccount) -> Void

    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var s3Secret = ""
    @State private var label = ""
    @State private var working = false
    @State private var status: (ok: Bool, text: String)?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a \(provider.label) account").font(DS.heading)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    guide
                    fields
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let s = status {
                    HStack(spacing: 6) { Dot(color: s.ok ? Theme.good : Theme.problem); Text(s.text).font(DS.secondary).lineLimit(3) }
                        .frame(maxWidth: 420, alignment: .leading).help(s.text)
                } else if working {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(provider == .s3 ? "Saving…" : "Waiting for the sign-in in your browser…").font(DS.secondary).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(provider == .s3 ? "Add account" : "Sign in with \(provider.label)…") { task = Task { await go() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(working || !valid)
            }
        }
        .padding(20)
        .frame(width: 680, height: 620)
        // closing the sheet stops a sign-in that is still waiting for the browser (and frees the port at once)
        .onDisappear { task?.cancel() }
    }

    private var valid: Bool {
        switch provider {
        case .s3: return !clientId.trimmingCharacters(in: .whitespaces).isEmpty && !s3Secret.isEmpty
        case .googleDrive: return !clientId.trimmingCharacters(in: .whitespaces).isEmpty && !clientSecret.isEmpty
        case .dropbox, .oneDrive: return !clientId.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: the guide

    private var guide: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("One-time setup")
            Text(intro).font(DS.body).foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1).").font(DS.body.weight(.semibold)).frame(width: 18, alignment: .trailing)
                    Text(step).font(DS.body).textSelection(.enabled)
                }
            }
            if let (title, url) = link {
                Button(title) { NSWorkspace.shared.open(url) }.buttonStyle(.link).foregroundStyle(Theme.accent).font(DS.body)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var intro: String {
        switch provider {
        case .googleDrive: return "Google lets an app use your Drive only through a “client” you register yourself, once. It takes a few minutes and costs nothing; after that, Data Syncer signs in with your Google account like any app. Data Syncer asks only for the drive.file permission: it can see and change just the files and folders it makes itself."
        case .dropbox: return "Dropbox lets an app in only through an “app” you register yourself, once (free, a few minutes). After that, Data Syncer signs in with your Dropbox account."
        case .oneDrive: return "Microsoft lets an app use OneDrive only through an “app registration” you make yourself, once (free, a few minutes). After that, Data Syncer signs in with your Microsoft account."
        case .s3: return "Data Syncer uses an access key you make in the AWS console (or your S3-compatible service), limited to one bucket. It never creates buckets; the bucket and the folder in it are chosen when you add the destination."
        }
    }

    private var steps: [String] {
        switch provider {
        case .googleDrive: return [
            "Open the Google Cloud Console (link below) and sign in. Create a project — any name, for example “Data Syncer”.",
            "APIs & Services → Library: find “Google Drive API” and turn it on.",
            "APIs & Services → OAuth consent screen: choose External, give the app a name and your e-mail address. Under Audience / Test users add your own Google address (the app stays in “testing”, which is fine for personal use).",
            "APIs & Services → Credentials → Create credentials → OAuth client ID → Application type “Desktop app”. Copy the Client ID and the Client secret it shows.",
            "Paste both below and press Sign in. Your browser opens; approve, and come back here.",
        ]
        case .dropbox: return [
            "Open the Dropbox App Console (link below) → Create app. Choose “Scoped access”, then “Full Dropbox” (or “App folder” if you'd rather keep Data Syncer inside one folder). Name it, for example “Data Syncer”.",
            "On the app's Permissions tab turn on files.metadata.read, files.metadata.write, files.content.read and files.content.write, then Submit.",
            "On the Settings tab, under OAuth 2 → Redirect URIs, add exactly:  \(OAuth.redirectURI)  and press Add.",
            "Copy the App key from the Settings tab, paste it below and press Sign in. Your browser opens; approve, and come back here.",
        ]
        case .oneDrive: return [
            "Open the Microsoft Entra admin center / Azure portal (link below) → App registrations → New registration. Name it “Data Syncer”. Under Supported account types choose “Personal Microsoft accounts only” (or the option that includes personal accounts).",
            "Under Redirect URI choose the platform “Mobile and desktop applications” and enter exactly:  \(OAuth.redirectURI)",
            "After registering, under Authentication set “Allow public client flows” to Yes and save.",
            "Under API permissions add Microsoft Graph → Delegated → Files.ReadWrite and offline_access (User.Read is there already).",
            "Copy the Application (client) ID from the Overview page, paste it below and press Sign in. Your browser opens; approve, and come back here.",
        ]
        case .s3: return [
            "In the AWS console open IAM → Users → Create user (for example “data-syncer”), with programmatic access only.",
            "Give it a policy limited to your backup bucket: s3:ListBucket on the bucket, and s3:GetObject, s3:PutObject, s3:DeleteObject, s3:AbortMultipartUpload on the bucket's objects.",
            "Create an access key for the user and copy the Access key ID and the Secret access key (the secret is shown once).",
            "Paste both below. The bucket, its region and the folder inside it are set on the destination; for an S3-compatible service (MinIO, Backblaze B2, Wasabi…) the destination also takes the service's address.",
        ]
        }
    }

    private var link: (String, URL)? {
        switch provider {
        case .googleDrive: return ("Open the Google Cloud Console", URL(string: "https://console.cloud.google.com/apis/credentials")!)
        case .dropbox: return ("Open the Dropbox App Console", URL(string: "https://www.dropbox.com/developers/apps")!)
        case .oneDrive: return ("Open Microsoft Entra app registrations", URL(string: "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)
        case .s3: return ("Open the AWS IAM console", URL(string: "https://console.aws.amazon.com/iam/")!)
        }
    }

    // MARK: fields

    @ViewBuilder private var fields: some View {
        Form {
            switch provider {
            case .googleDrive:
                TextField("Client ID", text: $clientId, prompt: Text("…apps.googleusercontent.com")).font(.system(.body, design: .monospaced))
                SecureField("Client secret", text: $clientSecret, prompt: Text("GOCSPX-…"))
            case .dropbox:
                TextField("App key", text: $clientId).font(.system(.body, design: .monospaced))
            case .oneDrive:
                TextField("Application (client) ID", text: $clientId, prompt: Text("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")).font(.system(.body, design: .monospaced))
            case .s3:
                TextField("Access key ID", text: $clientId, prompt: Text("AKIA…")).font(.system(.body, design: .monospaced))
                SecureField("Secret access key", text: $s3Secret)
                Field("Name for this account", $label, "optional — e.g. “my AWS”")
            }
            Text(provider == .s3 ? "The secret key goes in your Keychain." : "The browser window that opens is the service's own sign-in; Data Syncer never sees your password. Tokens go in your Keychain.")
                .font(DS.secondary).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: go

    private func go() async {
        working = true; status = nil
        let id = clientId.trimmingCharacters(in: .whitespaces)
        do {
            var account = CloudAccount(provider: provider, label: label.trimmingCharacters(in: .whitespaces), clientId: id)
            var secret = CloudSecret()
            switch provider {
            case .s3:
                secret.s3SecretKey = s3Secret
                if account.label.isEmpty { account.label = id }
            default:
                let config = provider.oauthConfig(clientId: id, clientSecret: provider == .googleDrive ? clientSecret : nil)!
                let tokens = try await OAuth.signIn(config) { NSWorkspace.shared.open($0) }
                secret.tokens = tokens
                secret.clientSecret = provider == .googleDrive ? clientSecret : nil
                let tp = TokenProvider(config: config, tokens: tokens) { _ in }
                switch provider {
                case .googleDrive: account.label = (try? await GoogleDriveStorage.whoAmI(tp)) ?? "Google Drive"
                case .dropbox: account.label = (try? await DropboxStorage.whoAmI(tp)) ?? "Dropbox"
                case .oneDrive: account.label = (try? await OneDriveStorage.whoAmI(tp)) ?? "OneDrive"
                case .s3: break
                }
            }
            guard !Task.isCancelled else { return }
            try secret.save(account.id, to: model.secrets)
            model.add(account)
            working = false
            onAdded(account)
            dismiss()
        } catch is CancellationError { return }
        catch let e as DSError { status = (false, e.message) } catch { status = (false, error.localizedDescription) }
        working = false
    }
}
