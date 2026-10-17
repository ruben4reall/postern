#if DEBUG
import AppKit
import PosternBridge
import SwiftUI

/// Renders each setup step in a window that is never put on screen. The sandbox keeps the app out of the rest of
/// the disk, so the images go to stdout as `name<TAB>base64` lines.
@MainActor
enum SetupSnapshots {
    static func write() {
        _ = NSApplication.shared
        let pin = CertificatePin(sha256Hex: "7F2193528AB83E4142D113FCB7C8623A64EB7066AFBBC3650BF1F1A010547168")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for step in OnboardingModel.Step.allCases {
                let model = OnboardingModel {}
                model.step = step
                model.bridgeVersion = "03.27.01"
                model.imap = PortIdentity(mode: .startTLS, greeting: "", pin: pin)
                if step == .signIn { model.username = "ruben@example.ch" }
                let view = NSHostingView(rootView: OnboardingView(model: model).background(Color(nsColor: .windowBackgroundColor)))
                view.frame = NSRect(x: 0, y: 0, width: 540, height: 500)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = "\(step.rawValue + 1)-\(step)-\(appearance == .aqua ? "light" : "dark").png"
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    print("\(name)\t\(png.base64EncodedString())")
                }
            }
        }
    }
}
#endif
