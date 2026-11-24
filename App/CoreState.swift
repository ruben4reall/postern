import Foundation
import PosternApproval
import PosternCore
import PosternVault

/// The Mac's core: the shared `CoreState` with the Keychain, the XPC reader, the panels and Touch ID.
extension CoreState {
    static let accessGroup = "D8HG34L8XK.ch.rubencatalao.postern"

    static let shared = CoreState(platform: CorePlatform(
        vault: KeychainVault(accessGroup: accessGroup),
        reader: ParserClient(),
        presenter: PanelPresenter(),
        authenticator: PolicyAuthenticator(),
        supportFolder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postern", isDirectory: true),
        version: Bundle.main.shortVersion,
        storeClosedMessage: "Postern cannot read its settings while the Mac is locked: macOS keeps the Keychain closed until someone unlocks it. Unlock the Mac, then try again."
    ))
}

/// Touch ID or an Apple Watch; the Mac password only when the user allowed it.
struct PolicyAuthenticator: Authenticating {
    func confirm(reason: String) async -> Bool {
        await Authenticator.confirm(KitText.localize(reason), allowPassword: CoreState.shared.policy.allowPasswordFallback) == .confirmed
    }
}
