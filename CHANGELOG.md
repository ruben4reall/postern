# Changelog

## 0.1.2 (unreleased)

- **Drafts keep their attachments when they are sent.** `send_draft` sent the text of a draft without its
  attachments, and `update_draft` dropped them too. Both now carry them, the panel lists them, and the bytes that
  leave are the ones you approved. If you sent drafts with attachments through 0.1.1, check your Sent folder.
- **`update_draft` takes `attachments`** to replace a draft's files; without it, they stay.
- **Calls made at the same time no longer hang.** Two apps, or one app calling two tools at once, could leave a call
  waiting until the client gave up. Postern now runs them one after the other on its Bridge session.

## 0.1.1 (2026-10-18)

Postern now updates itself.

- **Check for Updates** in the Postern menu and in the menu bar icon's menu. When a version is waiting, both items
  name it.
- **Automatic checks only if you say yes.** Postern asks once, over its window; Security › Updates changes it later.
  Once a day, it reads the list of versions on getpostern.vercel.app and downloads updates from GitHub.
- **Signed end to end.** The list of versions and every update are signed with Postern's own key (EdDSA), checked
  before anything is opened, and nothing installs until you click Install and Relaunch.
- **The only connection besides Bridge**, now named in the threat model with what it reveals: your IP address and
  Postern's version, nothing else.

## 0.1.0 (2026-10-18)

The first public version.

- **Read**: list mailboxes, search, read messages and conversations, cleaned of hidden text and invisible
  characters, with a sender verdict. Save attachments to `~/Downloads/Postern`.
- **Organize**: read, unread, star, move, archive, labels, new folders and labels, each change read back from Bridge.
- **Drafts**: write, change and delete drafts.
- **Send**: new emails, replies, forwards and drafts, each approved on a panel that shows everything, with Touch ID.
  Limits per hour and per day, allowed and trusted recipients, warnings about where recipients came from.
- **Delete**: move to Trash, or erase what is already in Trash or Spam, each time on a panel with Touch ID.
- **The app**: a main window with tiles for tools, mailboxes, apps, activity and security; one switch per tool behind
  Touch ID; hidden mailboxes; pause, also when the screen locks; one-click connection to Claude Code, Claude Desktop
  and Codex; a chained activity log.
