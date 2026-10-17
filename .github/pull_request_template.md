## What and why

## How I verified it

- [ ] `swift test` passes in `Packages/PosternKit`
- [ ] New behavior has tests (against the fake IMAP or SMTP servers when it talks to Bridge)
- [ ] The change keeps every rule in CONTRIBUTING.md (no client-reachable lock, nothing about the mail in logs, no new network destination)
- [ ] docs/ updated if a tool, a default or a protection changed
