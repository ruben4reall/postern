# Changelog

## 0.1.2 (unreleased)

- **Send from your aliases.** Add an alias of your Proton account under Send from in Postern's window (Touch ID);
  `send_message`, `create_draft`, `update_draft` and `forward_message` take `from`, replies leave from the address
  the original was sent to, and `list_addresses` lists them. Any other From is refused (`sender_not_allowed`), and a
  draft written from an address you did not add is not sent.
- **Write up to 500 drafts from one template, or from a spreadsheet.** `create_drafts` fills `{{name}}` in the
  subject, body and attachment names with each draft's values, for example one application per company with its own
  letter. The values can come from a CSV or JSON file in the outbox, one row per draft, as Numbers or Excel export it.
  Every draft is checked before any is saved, so a missing value or file stops the batch instead of leaving half of
  it; `dry_run` shows the first draft without saving anything. With `send_drafts`, 500 applications take two calls
  and one Touch ID.
- **Sort by search.** The organize tools take `search` instead of ids, to archive, move, label, star or mark as read
  every message a search finds, up to 1,000 at a time, such as the newsletters older than a month. `dry_run` lists
  them first and changes nothing. A search must name a condition besides its mailbox.
- **Find the people who have not answered.** `awaiting_reply` lists who you wrote to without an answer, the longest
  wait first: the follow-ups to write, such as job applications with no news. An answer is a reply in the
  conversation, or a later email from the same address or company domain, Spam included.
- **Read attachments without saving them.** `read_attachment` returns the text of a PDF, of a scanned PDF or a photo
  of a document (recognized on your Mac by Vision), of text, CSV, JSON, calendar and contact files, and of HTML as a
  person would see it. Everything is read in the sandboxed reader and marked untrusted, like the email it came in.
- **Conversations still load when you hide a mailbox.** Hiding a mailbox also hides All Mail, which left every
  conversation empty; `get_thread` now looks folder by folder then. It also reads only the header of the message
  instead of downloading it with its attachments.
- **Drafts keep their attachments when they are sent.** `send_draft` sent the text of a draft without its
  attachments, and `update_draft` dropped them too. Both now carry them, the panel lists them, and the bytes that
  leave are the ones you approved. If you sent drafts with attachments through 0.1.1, check your Sent folder.
- **Send a batch of drafts with one Touch ID.** `send_drafts` takes up to 500 drafts, or every draft a
  `create_drafts` batch saved, and shows them all on one panel: who they go to and from, the files and their total
  size, then each email with its recipients, warnings, subject, the start of the text and its attachments, with a
  filter to find one. Untick any that should wait, and one Touch ID sends the rest. Each email is still approved for
  its exact bytes. The tool is off until you turn it on.
- **Long batches pace themselves.** Approved emails leave one by one, two seconds apart for a short batch and thirty
  for a long one (`spacing_seconds` changes it), and when your hourly or daily limit is reached they wait for room
  instead of being refused. The panel says when the last should leave; `start_at` schedules the first, up to thirty
  days ahead. The Overview pane follows each batch with a Stop button, and `batch_status` and `cancel_batch` let apps
  do the same. Pausing Postern holds a batch; a draft leaves Drafts only once its email is sent, and deleting a draft
  holds its email back. No draft is sent by two batches, each email takes its place in the limits as it leaves, and
  it carries the time it leaves.
- **Attachments from folders inside the outbox**, such as `Letters/Acme.pdf`, and `list_outbox` lists what is there.
  A file attached to many drafts is read once and held once in memory.
- **Clearer sending errors.** An email Proton refuses comes back as `send_refused`, and one whose connection broke
  while Bridge was taking it as `send_uncertain`, so it is not sent twice by mistake. A batch retries an email Bridge
  did not take, and goes on past one Proton refused.
- **`update_draft` takes `attachments`** to replace a draft's files; without it, they stay.
- **Calls are up to 2.5 times faster.** After each call, Postern reread and rechecked its whole activity log, and
  the next call waited for it. It now checks only what was added since, with a full check every five minutes.
- **HTML emails no longer come out empty.** Font size and color are judged where the text inherits them, so a
  layout that sets a zero font size on a wrapper keeps its text, and rules meant for phones, print or dark mode no
  longer hide the desktop version. White text on a dark background set by a style sheet stays; text hidden by a
  style sheet class is now removed too.
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
