import PosternBridge
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// Shown when Postern is already set up and the setup runs again.
    var cancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .padding(.bottom, 16)
            }
            footer
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: 540, height: 500)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .detect:
            StepHeader(symbol: nil, title: "Postern guards your mailbox",
                       text: "Postern lets apps like Claude Code work with your Proton Mail, through Proton Mail Bridge on this Mac. You decide what they may do; nothing leaves without you.")
            Text("First, Postern looks for Bridge. Make sure it is open and signed in.")
                .foregroundStyle(.secondary)
                .padding(.top, 20)
        case .trust:
            StepHeader(symbol: "lock.shield", title: "Trust Bridge's certificate",
                       text: "Bridge \(model.bridgeVersion ?? "") encrypts its connection with this certificate. Postern will only ever talk to it, so another program cannot pretend to be Bridge.")
            if let pin = model.imap?.pin {
                Fingerprint(pin: pin).padding(.top, 20)
            }
            Text("To double-check, compare it with the certificate Bridge exports in Settings, Advanced settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
        case .signIn:
            StepHeader(symbol: "key", title: "Sign in to Bridge",
                       text: "In Proton Mail Bridge, open your account and copy the username and password shown under Mailbox details. This password is made by Bridge; it is not your Proton password.")
            VStack(spacing: 12) {
                TextField("Username", text: $model.username)
                    .textContentType(.username)
                SecureField("Bridge password", text: $model.password)
                    .textContentType(.password)
                    .onSubmit { Task { await model.connect() } }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .padding(.top, 20)
            Text("The password goes straight into your Mac's Keychain, where only Postern can read it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
        case .allow:
            StepHeader(symbol: "touchid", title: "Let your apps read your mail",
                       text: "With reading on, a connected app can list your mailboxes, search, and read messages and conversations.")
            VStack(alignment: .leading, spacing: 10) {
                Point(symbol: "eye.slash", text: "Hidden text, invisible characters and remote images are removed first.")
                Point(symbol: "exclamationmark.shield", text: "Every message is labeled as untrusted, with a verdict on its sender.")
                Point(symbol: "hand.raised", text: "Nothing can be sent, moved or deleted: those stay off.")
            }
            .padding(.top, 20)
        case .done:
            StepHeader(symbol: "checkmark.seal", title: "Postern is ready",
                       text: "Reading is on. Postern starts by itself when an app connects, even with this window closed. Open Postern from the Dock or Applications to choose what apps may do.")
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                    Circle()
                        .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if model.working { ProgressView().controlSize(.small).padding(.trailing, 8) }
            if let cancel, model.step != .done {
                Button("Cancel", action: cancel).controlSize(.large).keyboardShortcut(.cancelAction)
            }
            primaryButton
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let button: (String, () -> Void) = switch model.step {
        case .detect: ("Look for Bridge", { Task { await model.detect() } })
        case .trust: ("Trust This Certificate", { model.trust() })
        case .signIn: ("Connect", { Task { await model.connect() } })
        case .allow: ("Allow Reading", { Task { await model.allowReading() } })
        case .done: ("Done", { model.close() })
        }
        Button(button.0, action: button.1)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.working)
    }
}

private struct StepHeader: View {
    /// nil shows Postern's own symbol.
    let symbol: String?
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                } else {
                    PosternMark().fill(.primary).frame(width: 40, height: 40)
                }
            }
            .padding(.bottom, 4)
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Point: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
        }
    }
}

private struct Fingerprint: View {
    let pin: CertificatePin

    var body: some View {
        let groups = pin.display.split(separator: ":").map(String.init)
        let rows = stride(from: 0, to: groups.count, by: 8).map { Array(groups[$0..<min($0 + 8, groups.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            Text("SHA-256").font(.caption).foregroundStyle(.secondary)
            ForEach(rows.indices, id: \.self) { index in
                Text(rows[index].joined(separator: " "))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
