import Foundation
import PosternModel
import PosternPlatform
import PosternPolicy
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

// postern: Postern from a terminal, for Linux and Windows, desktop or server. Everything goes through the core, which
// asks the system for proof (polkit, Windows Hello) before anything gives apps more power.

let usage = """
Postern \(CoreService.version): a gate between your Proton Mail and the AI apps you connect to it.

Usage: postern <command>

  status                      What Postern allows, who is connected, today's sends
  setup                       Connect Postern to Proton Mail Bridge (asks for Bridge's username and password)
  tools                       List every tool and whether it is on
  tools on <tool>...          Turn tools on (asks the system for your password or fingerprint)
  tools off <tool>...         Turn tools off
  preset <read|assistant|full>
                              Read only; read, organize and write drafts; or everything up to sending
  apps                        List the AI apps Postern can connect to
  apps connect <app>          Add Postern to that app's settings (claudeCode, claudeDesktop, codex, cursor,
                              vscode, windsurf, geminiCLI, kiro, cline)
  mailboxes                   List the mailboxes apps can see
  mailboxes hide|show <name>  Hide a mailbox from apps, or show it again
  limits <per hour> <per day> Set the sending limits
  activity [count]            What apps did, newest first
  batches                     Batches of drafts and emails
  batches cancel <id>         Stop a batch
  pause | resume              Suspend every tool, or bring them back
  approvals                   Review emails and deletions waiting for you, in this terminal
  version                     Postern's version

Postern is an independent open-source project, not affiliated with Proton AG.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("postern: \(message)\n".utf8))
    exit(1)
}

func say(_ text: String = "") { print(text) }

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    say(usage)
    exit(0)
}
if ["help", "-h", "--help"].contains(command) {
    say(usage)
    exit(0)
}
if ["version", "--version", "-v"].contains(command) {
    say("Postern \(CoreService.version)")
    exit(0)
}

let client: ControlClient
do {
    client = try ControlClient()
} catch {
    fail("\(error)")
}

func call(_ method: String, _ params: ControlWire.Params? = nil) async -> ControlWire.Result {
    do {
        return try await client.call(method, params)
    } catch let failure as ControlWire.Failure {
        fail(failure.message)
    } catch {
        fail("\(error)")
    }
}

func status() async -> ControlWire.Status {
    guard let status = await call("status").status else { fail("The core gave no status.") }
    return status
}

func readSecret(_ prompt: String) -> String {
    #if os(Windows)
    print(prompt, terminator: "")
    let input = GetStdHandle(STD_INPUT_HANDLE)
    var mode: DWORD = 0
    GetConsoleMode(input, &mode)
    SetConsoleMode(input, mode & ~DWORD(ENABLE_ECHO_INPUT))
    defer {
        SetConsoleMode(input, mode)
        print()
    }
    return readLine(strippingNewline: true) ?? ""
    #else
    var settings = termios()
    let interactive = tcgetattr(STDIN_FILENO, &settings) == 0
    print(prompt, terminator: "")
    fflush(stdout)
    if interactive {
        var hidden = settings
        hidden.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
    }
    defer {
        if interactive { tcsetattr(STDIN_FILENO, TCSANOW, &settings) }
        print()
    }
    return readLine(strippingNewline: true) ?? ""
    #endif
}

func ask(_ question: String) -> Bool {
    print(question + " [y/N] ", terminator: "")
    fflush(stdout)
    return ["y", "yes", "o", "oui", "j", "ja", "s", "si", "sí"].contains((readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased())
}

func describe(_ status: ControlWire.Status) {
    let policy = status.policy
    say("Postern \(status.version) on \(status.system)")
    if !status.configured {
        say("Not set up: run `postern setup`.")
    } else {
        say("Account: \(status.account ?? "unknown") through Bridge (IMAP \(status.imapPort ?? 0), SMTP \(status.smtpPort ?? 0))")
    }
    if let problem = status.problem, status.configured { say("Problem: \(problem)") }
    say(policy.paused ? "Paused: apps see no tool." : "Tools on: \(policy.enabledTools.count) of \(ToolID.switchable.count)")
    say("Apps connected now: \(status.connectedApps.isEmpty ? "none" : status.connectedApps.joined(separator: ", "))")
    say("Sent through Postern: \(status.sendsLastHour) in the last hour (limit \(policy.sendsPerHour)), \(status.sendsLastDay) in the last day (limit \(policy.sendsPerDay))")
    if let hit = status.protonLimits.last {
        say("Proton's own limit stopped sending on \(hit.date.formatted(date: .abbreviated, time: .shortened)), after \(hit.sentInLastDay) emails in 24 hours.")
    }
    if !status.approvalsReady {
        switch status.approvalMethod {
        case "polkit": say("Approvals: polkit's actions are missing. Install Postern from its .deb or .rpm package to approve emails.")
        case "windows-hello": say("Approvals: open the Postern app once to set up Windows Hello.")
        default: break
        }
    }
    if status.pendingApprovals > 0 { say("\(status.pendingApprovals) approval(s) waiting: run `postern approvals` or open the app.") }
}

func toolID(_ name: String) -> ToolID {
    guard let tool = ToolID(rawValue: name), tool.companionOf == nil else {
        fail("There is no tool named \(name). `postern tools` lists them.")
    }
    return tool
}

func update(_ change: (inout Policy) -> Void) async {
    var policy = await status().policy
    change(&policy)
    let result = await call("policy.update", .init(policy: policy))
    if let status = result.status { describe(status) }
}

func setup() async {
    say("Postern connects to Proton Mail Bridge on this computer. Open Bridge and sign in first.")
    var imap = 1143
    var smtp = 1025
    for (index, argument) in arguments.enumerated() {
        if argument == "--imap-port", index + 1 < arguments.count, let port = Int(arguments[index + 1]) { imap = port }
        if argument == "--smtp-port", index + 1 < arguments.count, let port = Int(arguments[index + 1]) { smtp = port }
    }
    guard let detection = await call("setup.detect", .init(imapPort: imap, smtpPort: smtp)).detection else { fail("Bridge was not found.") }
    say("Found Proton Mail Bridge \(detection.bridgeVersion ?? "") on ports \(detection.imapPort) and \(detection.smtpPort).")
    say("Its certificate: \(detection.fingerprint)")
    guard ask("Does Bridge show the same certificate (Settings › Advanced › Export TLS certificates)? Postern trusts it from now on.") else {
        fail("Nothing was saved.")
    }
    print("Bridge username (the email address Bridge shows): ", terminator: "")
    fflush(stdout)
    let username = readLine() ?? ""
    let password = readSecret("Bridge password (the one Bridge generated, not your Proton password): ")
    _ = await call("setup.connect", .init(imapPort: imap, smtpPort: smtp, username: username, password: password, fingerprint: detection.fingerprint))
    say("Connected.")
    if ask("Let your apps read your mail now (list, search, read)? You can change this at any time.") {
        await update { $0.enabledTools.formUnion(Policy.readOnly.enabledTools) }
    }
    say("Next: `postern apps connect claudeCode` (or another app), then ask it about your mail.")
}

func listTools() async {
    guard let tools = await call("tools").tools else { return }
    for tier in ["read", "organize", "draft", "send", "delete"] {
        say("\n\(tier.capitalized)")
        for tool in tools where tool.tier == tier {
            say("  [\(tool.enabled ? "on " : "off")] \(tool.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(tool.title): \(tool.summary)")
        }
    }
}

func approvals() async {
    #if os(Linux)
    // polkit asks in this terminal when no desktop agent is running, as on a server.
    var agent: Process?
    if let pkttyagent = ["/usr/bin/pkttyagent", "/bin/pkttyagent"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
       ProcessInfo.processInfo.environment["DISPLAY"] == nil, ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] == nil {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pkttyagent)
        process.arguments = ["--process", "\(await status().processID)", "--fallback"]
        try? process.run()
        agent = process
    }
    defer { agent?.terminate() }
    #endif
    let queue = ApprovalQueue()
    client.onEvent { event, data in
        if event == "approval", let approval = data?.approval { queue.add(approval) }
    }
    say("Waiting for approvals. Ctrl-C to stop.")
    while true {
        guard let approval = await queue.next() else { continue }
        say("\n\(approval.client) wants to \(approval.kind == .deletion ? (approval.permanent ? "erase messages for good" : "move messages to Trash") : "send \(approval.batch?.count ?? 1) email(s)") (\(approval.tool))")
        if let context = approval.context { say(context) }
        for email in [approval.email].compactMap({ $0 }) + (approval.batch ?? []) {
            say("──────────")
            say("From: \(email.from)\nTo: \(email.to.joined(separator: ", "))")
            if !email.cc.isEmpty { say("Cc: \(email.cc.joined(separator: ", "))") }
            if !email.bcc.isEmpty { say("Bcc: \(email.bcc.joined(separator: ", "))") }
            say("Subject: \(email.subject)\n\n\(email.body)")
            if let quoted = email.quoted { say("\n" + quoted.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")) }
            for file in email.attachments { say("Attached: \(file.name) (\(file.type), \(file.size) bytes)") }
            for (address, badges) in email.badges where !badges.isEmpty { say("Note on \(address): \(badges.joined(separator: ", "))") }
            if let missing = email.missingAttachment { say("Warning: the text says \"\(missing)\" but no file is attached.") }
        }
        for row in approval.deletion ?? [] { say("- \(row.mailbox): \(row.from), \(row.subject)") }
        say("──────────")
        print("[s]end/delete, [d]raft, [r]eject? ", terminator: "")
        fflush(stdout)
        let answer = (readLine() ?? "").lowercased()
        let decision: ControlWire.Decision = answer.hasPrefix("s") ? .send : answer.hasPrefix("d") ? .draft : .reject
        _ = try? await client.call("approval.decide", .init(id: approval.id, decision: decision))
        if decision == .send { say("The system now asks for your password or fingerprint.") }
    }
}

/// Approvals as they come, one at a time.
actor ApprovalQueue {
    private var items: [ControlWire.Approval] = []
    private var seen: Set<String> = []

    nonisolated func add(_ approval: ControlWire.Approval) { Task { await insert(approval) } }

    private func insert(_ approval: ControlWire.Approval) {
        guard seen.insert(approval.id).inserted else { return }
        items.append(approval)
    }

    func next() async -> ControlWire.Approval? {
        while items.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        return items.removeFirst()
    }
}

let rest = Array(arguments.dropFirst())
switch command {
case "status":
    describe(await status())
case "setup":
    await setup()
case "tools":
    switch rest.first {
    case nil: await listTools()
    case "on": await update { policy in for name in rest.dropFirst() { policy.enabledTools.insert(toolID(name)) } }
    case "off": await update { policy in for name in rest.dropFirst() { policy.enabledTools.remove(toolID(name)) } }
    default: fail("Use `postern tools`, `postern tools on <tool>` or `postern tools off <tool>`.")
    }
case "preset":
    let read = Policy.readOnly.enabledTools.union([.getMessages, .topSenders, .awaitingReply, .readAttachment, .listAddresses])
    let organize = Set(ToolID.switchable.filter { $0.tier == .organize })
    let drafts: Set<ToolID> = [.createDraft, .updateDraft, .draftReply, .draftForward]
    let send: Set<ToolID> = [.sendMessage, .replyToMessage, .forwardMessage, .sendDraft]
    switch rest.first {
    case "read": await update { $0.enabledTools = read }
    case "assistant": await update { $0.enabledTools = read.union(organize).union(drafts) }
    case "full": await update { $0.enabledTools = read.union(organize).union(drafts).union(send) }
    default: fail("Use `postern preset read`, `assistant` or `full`.")
    }
case "apps":
    if rest.first == "connect", rest.count == 2 {
        let apps = await call("apps.connect", .init(app: rest[1])).apps ?? []
        if let app = apps.first(where: { $0.id == rest[1] }) { say("\(app.title): \(app.status) (\(app.path))") }
        say("Restart the app so it loads Postern.")
    } else {
        for app in await call("apps").apps ?? [] {
            let id = app.id.padding(toLength: 14, withPad: " ", startingAt: 0)
            let title = app.title.padding(toLength: 22, withPad: " ", startingAt: 0)
            let found = (app.installed ? "installed" : "not found").padding(toLength: 10, withPad: " ", startingAt: 0)
            say("\(id) \(title) \(found) \(app.status)")
        }
    }
case "mailboxes":
    if rest.count == 2, ["hide", "show"].contains(rest[0]) {
        await update { policy in
            if rest[0] == "hide" { policy.hiddenMailboxes.insert(rest[1]) } else { policy.hiddenMailboxes.remove(rest[1]) }
        }
    } else {
        for mailbox in await call("mailboxes").mailboxes ?? [] { say("\(mailbox.hidden ? "hidden " : "visible") \(mailbox.name)") }
    }
case "limits":
    guard rest.count == 2, let hour = Int(rest[0]), let day = Int(rest[1]) else { fail("Use `postern limits <per hour> <per day>`.") }
    await update { policy in
        policy.sendsPerHour = hour
        policy.sendsPerDay = day
    }
case "activity":
    let limit = rest.first.flatMap(Int.init) ?? 30
    for row in await call("activity", .init(limit: limit)).activity ?? [] {
        say("\(row.date.formatted(date: .abbreviated, time: .standard))  \(row.client)  \(row.tool)  \(row.outcome)\(row.items.map { "  \($0) item(s)" } ?? "")")
    }
case "batches":
    if rest.first == "cancel", rest.count == 2 {
        _ = await call("batches.cancel", .init(id: rest[1]))
        say("Stopped. The emails not sent yet stay in Drafts.")
    } else {
        let batches = await call("batches").batches ?? []
        if batches.isEmpty { say("No batch.") }
        for batch in batches {
            say("\(batch.id)  \(batch.kind)  \(batch.client)  \(batch.done)/\(batch.total) done  \(batch.phase)\(batch.reason.map { ": \($0)" } ?? "")")
        }
    }
case "pause":
    _ = await call("pause", .init(paused: true))
    say("Paused: apps see no tool until you resume.")
case "resume":
    _ = await call("pause", .init(paused: false))
    say("Resumed.")
case "approvals":
    await approvals()
default:
    say(usage)
    exit(1)
}
exit(0)
