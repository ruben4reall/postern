import Foundation
import PosternApproval
import PosternCompose
import PosternModel
import PosternVault
#if os(Windows)
import _CryptoExtras
import Crypto
#endif

/// Shows approvals in Postern's window: the core sends each one to every open window (and opens the app when none
/// is), and the first answer counts. The window only collects the choice: the proof that it is the user comes
/// afterwards, from the system (`ApprovalProof`), asked by the core itself.
extension Address {
    /// `Anna <anna@example.com>`, or the address alone.
    var shown: String { name.map { "\($0) <\(email)>" } ?? email }
}

final class RemotePresenter: ApprovalPresenter, @unchecked Sendable {
    weak var service: CoreService?

    private struct Waiting {
        let approval: ControlWire.Approval
        let continuation: CheckedContinuation<(ControlWire.Decision, String?, [String]?)?, Never>
    }

    private let lock = NSLock()
    private var waiting: [String: Waiting] = [:]

    func pending() -> [ControlWire.Approval] {
        lock.withLock { waiting.values.map(\.approval).sorted { $0.deadline < $1.deadline } }
    }

    /// Records the user's choice. False when the approval is no longer waiting.
    func decide(_ id: String, decision: ControlWire.Decision, reason: String?, chosen: [String]?) -> Bool {
        guard let entry = lock.withLock({ waiting.removeValue(forKey: id) }) else { return false }
        entry.continuation.resume(returning: (decision, reason, chosen))
        service?.broadcast(event: "approval.closed", data: .init(text: id))
        return true
    }

    private func ask(_ approval: ControlWire.Approval) async -> (ControlWire.Decision, String?, [String]?)? {
        let id = approval.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock { waiting[id] = Waiting(approval: approval, continuation: continuation) }
                service?.broadcast(event: "approval", data: .init(approval: approval))
                if service?.hasInterface != true { AppLauncher.openForApproval() }
            }
        } onCancel: {
            // The desk gave up waiting: the request expired.
            if let entry = lock.withLock({ waiting.removeValue(forKey: id) }) {
                entry.continuation.resume(returning: nil)
                service?.broadcast(event: "approval.closed", data: .init(text: id))
            }
        }
    }

    func present(_ request: ApprovalRequest, deadline: Date) async -> ApprovalIntent {
        let approval = ControlWire.Approval(
            id: request.id.uuidString, kind: .email, client: request.client, tool: request.tool, deadline: deadline,
            context: request.context, email: Self.email(request.message, id: request.id.uuidString, badges: request.badges, missing: nil),
            batch: nil, deletion: nil, permanent: false
        )
        switch await ask(approval)?.0 {
        case .send?: return .send
        case .draft?: return .saveAsDraft
        case .reject?: return .reject(reason: nil)
        case nil: return .reject(reason: nil)
        }
    }

    func presentDeletion(_ request: DeletionRequest, deadline: Date) async -> ApprovalIntent {
        let approval = ControlWire.Approval(
            id: request.id.uuidString, kind: .deletion, client: request.client, tool: request.tool, deadline: deadline,
            context: nil, email: nil, batch: nil,
            deletion: request.items.map { .init(mailbox: $0.mailbox, from: $0.from, subject: $0.subject, date: $0.date) },
            permanent: request.permanent
        )
        let answer = await ask(approval)
        return answer?.0 == ControlWire.Decision.send ? ApprovalIntent.send : ApprovalIntent.reject(reason: answer?.1)
    }

    func presentBatch(_ request: BatchApprovalRequest, deadline: Date) async -> BatchIntent {
        let approval = ControlWire.Approval(
            id: request.id.uuidString, kind: .batch, client: request.client, tool: request.tool, deadline: deadline,
            context: nil, email: nil,
            batch: request.items.map { item in
                ControlWire.Email(
                    id: item.id.uuidString, from: item.from.shown, to: item.to.map(\.shown), cc: item.cc.map(\.shown),
                    bcc: item.bcc.map(\.shown), subject: item.subject, body: item.text, quoted: nil,
                    attachments: item.files.map { .init(name: $0.filename, type: $0.mimeType, size: $0.size) },
                    badges: item.badges.mapValues { $0.map(\.rawValue) }, missingAttachment: item.missingAttachment
                )
            },
            deletion: nil, permanent: false
        )
        guard let answer = await ask(approval) else { return .reject(reason: nil) }
        guard answer.0 == ControlWire.Decision.send else { return BatchIntent.reject(reason: answer.1) }
        let chosen = Set(answer.2 ?? request.items.map(\.id.uuidString))
        let ids: Set<UUID> = Set(request.items.filter { chosen.contains($0.id.uuidString) }.map(\.id))
        return BatchIntent.send(ids)
    }

    static func email(_ message: OutgoingMessage, id: String, badges: [String: [ApprovalBadge]], missing: String?) -> ControlWire.Email {
        ControlWire.Email(
            id: id, from: message.from.shown, to: message.to.map(\.shown), cc: message.cc.map(\.shown),
            bcc: message.bcc.map(\.shown), subject: message.subject, body: message.body, quoted: message.quoted,
            attachments: message.attachments.map { .init(name: $0.filename, type: $0.mimeType, size: $0.data.count) },
            badges: badges.mapValues { $0.map(\.rawValue) }, missingAttachment: missing
        )
    }
}

/// The system's proof that the person at the computer approved, asked by the core after the user chose Send or
/// Delete in the window, and before any change that gives apps more power.
///
/// - Linux: polkit (`pkcheck`), which asks for the user's password or fingerprint in the desktop's own dialog.
/// - Windows: a Windows Hello signature (face, fingerprint or PIN) over a challenge made by the core, verified
///   against the public key registered once at setup. The window cannot sign without the user's gesture.
final class ApprovalProof: Authenticating, @unchecked Sendable {
    weak var service: CoreService?
    private let lock = NSLock()
    private var signatures: [String: CheckedContinuation<Data?, Never>] = [:]

    func confirm(reason: String) async -> Bool {
        #if os(Linux)
        return await PolkitAuthenticator(action: .approve).confirm(reason: reason)
        #elseif os(Windows)
        return await helloConfirm(reason: reason)
        #else
        return false
        #endif
    }

    func confirmPolicyChange(reason: String) async -> Bool {
        #if os(Linux)
        return await PolkitAuthenticator(action: .changePolicy).confirm(reason: reason)
        #elseif os(Windows)
        return await helloConfirm(reason: reason)
        #else
        return false
        #endif
    }

    /// The app hands back the signature Windows Hello made.
    func signed(_ id: String, signature: Data) {
        let waiting = lock.withLock { signatures.removeValue(forKey: id) }
        waiting?.resume(returning: signature)
    }

    func registeredKey(in vault: any SecretStore) -> Data? {
        (try? vault.data(for: .approvalKey)) ?? nil
    }

    /// Pins the public key of the Windows Hello credential, once. Replacing it takes forgetting the setup first.
    func register(_ key: Data, vault: any SecretStore) throws {
        #if os(Windows)
        guard registeredKey(in: vault) == nil else {
            throw ControlWire.Failure("already_registered", "A Windows Hello key is already registered. Forget the setup first to register another.")
        }
        guard (try? _RSA.Signing.PublicKey(derRepresentation: key)) != nil else {
            throw ControlWire.Failure("invalid", "This is not a Windows Hello public key.")
        }
        try vault.set(key, for: .approvalKey)
        #else
        throw ControlWire.Failure("unsupported", "Keys are registered on Windows only.")
        #endif
    }

    #if os(Windows)
    private func helloConfirm(reason: String) async -> Bool {
        guard let service, let keyData = registeredKey(in: service.core.vault),
              let key = try? _RSA.Signing.PublicKey(derRepresentation: keyData) else { return false }
        let id = UUID().uuidString
        var nonce = Data(count: 32)
        for index in nonce.indices { nonce[index] = UInt8.random(in: 0...255) }
        // What the user's gesture signs: a fresh challenge bound to this approval and its reason.
        let challenge = Data("postern-approval-v1\n\(id)\n\(reason)\n".utf8) + nonce
        if !service.hasInterface { AppLauncher.openForApproval() }
        let signature: Data? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock { signatures[id] = continuation }
                service.broadcast(event: "auth.sign", data: .init(sign: .init(id: id, challenge: challenge.base64EncodedString(), reason: reason)))
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [weak self] in
                    let late = self?.lock.withLock { self?.signatures.removeValue(forKey: id) }
                    late??.resume(returning: nil)
                }
            }
        } onCancel: {
            let waiting = lock.withLock { signatures.removeValue(forKey: id) }
            waiting?.resume(returning: nil)
        }
        guard let signature else { return false }
        let digest = SHA256.hash(data: challenge)
        // Windows Hello signs with RSASSA-PKCS1-v1_5 over SHA-256; PSS is accepted too, for keys made that way.
        let rsa = _RSA.Signing.RSASignature(rawRepresentation: signature)
        return key.isValidSignature(rsa, for: digest, padding: .insecurePKCS1v1_5) || key.isValidSignature(rsa, for: digest, padding: .PSS)
    }
    #endif
}

/// Opens Postern's window when something waits for the user and no window is open.
enum AppLauncher {
    static func openForApproval() {
        #if os(Linux)
        guard let app = PosternPaths.program("postern-app") else { return }
        spawnDetached(app, arguments: ["--approvals"])
        #elseif os(Windows)
        guard let app = PosternPaths.program("Postern") else { return }
        spawnDetached(app, arguments: ["--approvals"])
        #endif
    }

    static func spawnDetached(_ program: URL, arguments: [String]) {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
