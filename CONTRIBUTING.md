# Contributing to Postern

Thank you for helping. Postern stands between strangers' email and an app that can act on it, so every change is
held to one question: could this let something the client controls open a lock? This guide explains how the project
is laid out, how to run it, and the rules that keep that answer "no".

- [Ways to help](#ways-to-help)
- [Project layout](#project-layout)
- [Run the tests](#run-the-tests)
- [Build the app with your own team](#build-the-app-with-your-own-team)
- [Rules every change keeps](#rules-every-change-keeps)
- [Adding a tool](#adding-a-tool)
- [Bridge behaviors worth knowing](#bridge-behaviors-worth-knowing)
- [Style](#style)
- [Pull requests](#pull-requests)

## Ways to help

- **Report a bug** with the [bug report form](https://github.com/ruben4reall/postern/issues/new?template=bug_report.yml).
  Say what you asked the app, what Postern did, and the Activity entry if there is one. Never paste the content of a
  real email.
- **Suggest a feature** with the [feature form](https://github.com/ruben4reall/postern/issues/new?template=feature_request.yml).
- **Send a hostile email** that gets past the reader: hidden text, a forged sender, a parser crash. Please report it
  privately as described in [SECURITY.md](SECURITY.md).
- **Fix something.** Issues labeled `good first issue` are a gentle start.

## Project layout

```
App/                 Postern.app: the core. MCP sessions, policy, approvals, Keychain, the window.
  Approval/          The approval panels (send and delete).
  Control/           The main window and its model.
  Onboarding/        The setup sheet.
  Debug/             Debug-only tools (the self-test).
ParserService/       The sandboxed XPC service that decodes every message.
Relay/               postern-mcp, the stdio relay that MCP clients launch.
Shared/              XPC protocols and names shared by the three processes.
Packages/PosternKit/ Everything that can be tested without the app:
  PosternModel       Plain value types: message ids, tools, errors, queries.
  PosternText        Encoded words, Unicode cleanup, dates.
  PosternMail        MIME parser, HTML sanitizer, sender verdict, message sanitizer.
  PosternBridge      IMAP and SMTP over SwiftNIO with a pinned certificate, the Organizer.
  PosternVault       The Keychain.
  PosternPolicy      Tiers, switches, hidden mailboxes, limits, what adds power.
  PosternCompose     Outgoing messages: validation, rendering, attachments, digest.
  PosternApproval    The approval desk: the only producer of approved messages and deletions.
  PosternServer      The MCP tools and sessions.
  PosternAudit       The chained activity log.
  PosternClients     Reading and writing the settings of Claude Code, Claude Desktop and Codex.
docs/                Threat model, architecture, tool reference, images.
scripts/             Build, install and offscreen screenshots.
```

[docs/architecture.md](docs/architecture.md) explains how the pieces talk to each other.

## Run the tests

You need Xcode 26 (Swift 6.2 or later) on macOS 26.

```bash
cd Packages/PosternKit
swift test
```

The tests never touch a real mailbox. `Tests/PosternBridgeTests` runs fake IMAP and SMTP servers on the loopback
address, with a test certificate, and a `FakeMailStore` that behaves like Proton through Bridge (labels, UIDs that
change on every move, views that lag behind). When you find a Bridge behavior the fake does not have, add it to the
fake first, with a comment saying where it was seen, then write the test that fails, then fix the code.

If a test crashes with signal 11 after you add a case to an enum or a field to a struct, the build is stale:

```bash
rm -rf .build/arm64-apple-macosx/debug/Postern*.build .build/arm64-apple-macosx/debug/Modules/Postern*
```

## Build the app with your own team

The app relies on its code signature: the Keychain access group, the Mach service names and the check every XPC
connection makes on the other side all carry the developer's team identifier. To build it under your own Apple team,
replace `D8HG34L8XK` with your team identifier in:

- `project.yml` (`DEVELOPMENT_TEAM`)
- `Shared/XPCProtocols.swift` (service names and `teamRequirement`)
- `App/LaunchAgents/ch.rubencatalao.postern.core.plist` (Mach services)
- `App/CoreState.swift` (`accessGroup`)

and the bundle identifiers in `project.yml` if you want to keep your build apart from a released Postern. Then:

```bash
brew install xcodegen
scripts/build.sh
```

`scripts/build.sh` generates the Xcode project, builds a Debug version at background priority, installs it in
`~/Applications` and registers the launch agent. The data protection Keychain needs a provisioning profile, which
Xcode creates when you sign in with your Apple account (`-allowProvisioningUpdates`).

`scripts/snapshot-control.sh <folder>` draws every pane and panel, light and dark, with sample data, in windows placed
outside every display, so nothing shows on screen.

Debug builds also have `--selftest`, which checks attachments and Trash against your real Bridge **on messages it
creates itself and nothing else**: a message created in Inbox, a draft, and an email sent to your own address, each
with two attachments, all put in Trash at the end. It never erases.

### Releases

Maintainers build releases with `scripts/release.sh`: a Release archive signed with a Developer ID, notarized and
stapled, packed in a disk image laid out by `dmgbuild` (no Finder window). It then runs `scripts/finish-release.sh`,
which signs the disk image with Postern's EdDSA key (kept in the maintainer's Keychain, never in the repository), adds
it to the signed update feed `site/appcast.xml`, and writes the release notes and the Homebrew cask. Nothing is
published until `scripts/publish.sh` runs its three steps, `release`, `tap` and `site`, each on the maintainer's
go-ahead.

Every release raises `MARKETING_VERSION` and the build number `CURRENT_PROJECT_VERSION` (a whole number, the one
Sparkle compares) in `project.yml`, and has a section in [CHANGELOG.md](CHANGELOG.md). `scripts/tests/run.sh` checks
the release scripts without signing anything; CI runs it.

## Rules every change keeps

These come from the threat model. A pull request that breaks one will not be merged, however useful it is.

1. **Authority stays out of the client's reach.** No tool argument, environment variable, file or local port may
   turn a switch on, skip a panel, or raise a limit. Only the Postern window changes the policy, and anything that
   adds power asks for Touch ID first.
2. **A tool that is off does not exist.** It is not listed and cannot be called.
3. **Sending and deleting go through the desk.** `SMTPClient` accepts only an `ApprovedMessage`, and the Organizer
   trashes or erases only an `ApprovedDeletion`. Both have internal initializers in `PosternApproval`; keep it that way.
4. **Mail content is untrusted.** Anything that came from an email reaches the client inside the untrusted envelope,
   and is decoded only in the parser service.
5. **Fail closed.** Missing or unreadable policy means read-only. A different certificate means no connection. A
   panel that times out means no.
6. **Nothing about the mail on disk or in logs.** Log names of hosts and headers, codes and counts, never content,
   addresses or subjects. Mark anything else `privacy: .private`.
7. **No new network destination.** Postern talks to Bridge on the loopback address, and to the update feed and
   GitHub Releases through Sparkle when the user allows it. Nowhere else.
8. **Dependencies are pinned exactly**, and a new one needs a reason in the pull request.

## Adding a tool

1. Add the case to `ToolID` with its tier (`PosternModel`).
2. Describe it in `ToolCatalog` (title, description, input schema, annotations). Destructive tools get
   `destructiveHint`; tools that send or delete also get `anthropic/requiresUserInteraction`.
3. Implement it in `PosternServer`, behind `MailBackend`, with tests against the fakes.
4. Add its copy to `ToolCopy` in `App/Control/ControlModel.swift`: what it lets an app do, what could go wrong.
5. Document it in [docs/tools.md](docs/tools.md). A test fails while a tool is missing from that page.
6. New tools start off. Do not add them to `Policy.readOnly`.

## Bridge behaviors worth knowing

Seen on Proton Mail Bridge 3.27, each one with a test in the fakes:

- **Header order means nothing.** Bridge rebuilds the header block: Proton's `Received` first, then the sender's,
  then four `Authentication-Results: mail.protonmail.ch`, then Bridge's `X-Pm-*` headers. A forged result shows up
  as a method written twice under Proton's name.
- **TLS mode differs by port.** On the reference Mac, IMAP 1143 uses STARTTLS and SMTP 1025 uses TLS from the first
  byte. Bridge offers `AUTH=PLAIN` before encryption: Postern never uses it there.
- **`LIST "" ("*")` is refused.** Use `LIST "" "*"`.
- **Labels are mailboxes.** Moving a message into `Labels/X` applies the label and keeps it in its folder; moving it
  out of a label mailbox removes the label. Never expunge inside a label mailbox.
- **UIDs change on every move.** Find a message again by its Message-ID.
- **Views lag behind.** After a move, other mailboxes can show the message for a few seconds. Moving it again from
  such a view into Trash, where it already is, makes Bridge erase it for good. The Organizer never moves a message
  where its Message-ID already is.
- **A message sent to yourself is one message**, shown in Inbox and in Sent.

## Style

- Swift 6 with strict concurrency. Closures handed to XPC are `@Sendable`, or the process traps at runtime.
- Comments say why, not what. Doc comments on every public type.
- English everywhere in the repository. Visible text uses plain words and short sentences, and avoids long dashes.
- Match the surrounding code before reaching for a new pattern.

## Pull requests

- One change per pull request, with tests. Explain the why in the description, and how you verified it.
- CI runs the package tests on macOS 26 and must be green.
- Commits are squashed on merge, so the history reads one change per line.

By contributing, you agree that your work is released under the [MIT license](LICENSE), and you follow the
[code of conduct](CODE_OF_CONDUCT.md).
