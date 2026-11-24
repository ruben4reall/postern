import Foundation

// postern-app: Postern's window on Linux (GTK 4 and libadwaita). The core runs apart and keeps serving apps when
// the window is closed; the window opens by itself when an email waits for approval.

#if os(Linux)
// `--demo <pane>` fills the window with sample data and never talks to the core: for screenshots and reviews.
let demo: Pane? = CommandLine.arguments.firstIndex(of: "--demo").flatMap { index in
    index + 1 < CommandLine.arguments.count ? Pane(rawValue: CommandLine.arguments[index + 1]) : .overview
}
let app = PosternApp(demo: demo)
if CommandLine.arguments.contains("--demo-approval") { DemoApproval.schedule(app) }
exit(app.run())
#else
print("The Postern window is the Linux app. On a Mac, use Postern.app; on Windows, Postern for Windows.")
exit(1)
#endif
