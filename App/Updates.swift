import AppKit
import Observation
import Sparkle

/// Software updates, and the only connection Postern makes besides Bridge: Sparkle reads the signed feed on
/// getpostern.vercel.app and installs disk images from GitHub Releases signed with Postern's EdDSA key. Automatic
/// checks stay off until you say yes, in the window or in Security, and every update waits for "Install and Relaunch".
/// Debug builds never start it, so a development copy is never replaced by a release.
@MainActor @Observable
final class Updates {
    /// Sparkle's own setting. Absent until you answer, since the Info.plist leaves it out on purpose.
    static let automaticChecksKey = "SUEnableAutomaticChecks"

    /// False in debug builds: nothing checks, nothing installs.
    let active: Bool
    /// False while a check or an installation runs.
    private(set) var canCheck = false
    private(set) var checksAutomatically = false
    /// A version a scheduled check found that nobody has looked at yet. Postern usually has no Dock icon, so its
    /// menus name it.
    private(set) var pendingVersion: String?
    /// Called just before Sparkle quits Postern to install an update.
    @ObservationIgnored var willRelaunch: (@MainActor () -> Void)?

    @ObservationIgnored private let delegate = SparkleDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
        #if DEBUG
        active = false
        #else
        active = true
        #endif
        delegate.pendingChanged = { [weak self] version in self?.pendingVersion = version }
        delegate.willRelaunch = { [weak self] in self?.willRelaunch?() }
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
        ]
        if active { controller.startUpdater() }
        refresh()
    }

    /// "Check for Updates…", or the version waiting for you.
    var menuTitle: String {
        pendingVersion.map { "Update to Postern \($0)…" } ?? "Check for Updates…"
    }

    /// The version and build of this copy, as the About panel shows them.
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    func checkForUpdates() {
        guard canCheck else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    func setChecksAutomatically(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
        refresh()
    }

    /// Asks once, over the window you opened, whether Postern may check on its own. Sparkle would ask on its second
    /// launch, and launchd starts Postern whenever an app connects: the question would pop up at a random moment.
    func askAboutAutomaticChecks(in window: NSWindow) {
        guard active, UserDefaults.standard.object(forKey: Self.automaticChecksKey) == nil, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Check for updates automatically?"
        alert.informativeText = """
            Once a day, Postern can look for a new version on getpostern.vercel.app. Updates come from GitHub, signed \
            by Postern's developer, and nothing is installed without asking you. Apart from Bridge, this is the only \
            connection Postern makes. You can change this later in Security.
            """
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")
        alert.beginSheetModal(for: window) { [weak self] response in
            // Closed by an update about to install: no answer yet, the question comes back next time.
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            self?.setChecksAutomatically(response == .alertFirstButtonReturn)
        }
    }

    private func refresh() {
        canCheck = active && controller.updater.canCheckForUpdates
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }
}

/// Sparkle's delegates: no permission prompt of its own, and gentle reminders for an app without a Dock icon, so a
/// version found by a scheduled check is named in the menus instead of taking the focus from the app in use.
@MainActor
private final class SparkleDelegate: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    var pendingChanged: ((String?) -> Void)?
    var willRelaunch: (() -> Void)?

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    /// Called right before the installer asks Postern to quit.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { willRelaunch?() }

    /// The feed named in the Info.plist, and no other: Sparkle would also take one from the preferences, which any
    /// program running as you can write. The signatures would still hold, but there is no reason to ask elsewhere.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        pendingChanged?(update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingChanged?(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingChanged?(nil)
    }
}
