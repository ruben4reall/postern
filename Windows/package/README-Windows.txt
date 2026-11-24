Postern for Windows, preview
=============================

Postern is the Proton Mail MCP server: it lets Claude, Codex, Cursor, VS Code and other AI apps use your Proton Mail
through Proton Mail Bridge, within the limits you set. This is a preview of Postern for Windows: the core, the relay
AI apps launch, the jailed message reader and the command line. Approvals open in a console window and are signed
by Windows Hello (face, fingerprint or PIN). The Windows app comes later.

You need Windows 11, Windows Hello set up (a PIN is enough: Settings > Accounts > Sign-in options) and Proton Mail
Bridge, running and signed in.

1. Unzip this archive, then in that folder run:
       powershell -ExecutionPolicy Bypass -File .\install.ps1
2. Open a new terminal and run:
       postern setup
   Postern finds Bridge, shows its certificate, asks for the username and password Bridge shows under your
   account's Mailbox details, and creates your Windows Hello key.
3. Choose what apps may do:
       postern preset read          (or assistant, or full)
4. Connect your apps, then restart them:
       postern apps                 (lists them)
       postern apps connect claudeCode
5. When an app wants to send or delete, a console window opens with the whole email. Type s to send, then
   confirm with Windows Hello.

More: https://github.com/ruben4reall/postern
Postern is an independent open-source project, not affiliated with Proton AG.
