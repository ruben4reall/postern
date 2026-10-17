# Security policy

Postern guards access to a mailbox, so security reports get priority over everything else.

## Report a vulnerability

Please report privately, with [GitHub's private vulnerability reporting](https://github.com/ruben4reall/postern/security/advisories/new).
Do not open a public issue, and do not include the content of a real email.

A good report says:

- what an attacker controls (an email they send, a local program, a client),
- what they obtain (reading what should be hidden, sending without approval, the Bridge password, a crash),
- how to reproduce it, ideally with a crafted `.eml` file built for the purpose,
- the versions of Postern, macOS and Proton Mail Bridge.

## What to expect

- An answer within 3 days.
- An assessment within 10 days, with a plan and a date for the fix.
- Credit in the release notes and the advisory, unless you prefer otherwise.

Please give a reasonable time for a fix to ship before talking about the issue in public.

## In scope

- Anything that lets an MCP client, an email, or another local program without administrator rights:
  - use a tool that is turned off, or see a hidden mailbox,
  - send or delete mail without the approval panel and Touch ID,
  - change the policy, raise a limit, or reach the Keychain items,
  - get the Bridge password,
  - talk to Postern's processes without Postern's signature.
- Hidden text or instructions that reach the client outside the untrusted envelope.
- A forged sender that Postern reports as verified.
- Crashes or memory bugs in the parser service from a crafted message.

## Out of scope

- An attacker with administrator rights, your login password, or control of your screen.
- Proton Mail Bridge and Proton's servers: please report those to [Proton](https://proton.me/security/bug-bounty).
- What a client does with mail you allowed it to read, and emails you approved yourself.

## Supported versions

Only the latest release gets security fixes.

The threat model behind these choices is in [docs/threat-model.md](docs/threat-model.md).
