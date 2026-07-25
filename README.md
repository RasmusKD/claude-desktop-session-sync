# claude-desktop-session-sync

Keep your Claude Code chat list when switching accounts in the **Claude desktop app** on Windows.

## The problem

The Claude desktop app scopes its chat/session list to the logged-in account. Switch accounts (work ↔ personal, Team → Personal) and your sidebar goes empty — the chats still exist on disk, but the app only shows the current account's slice. This is a widely reported limitation with no official solution:

- [Desktop app: session history lost when switching accounts (#48511)](https://github.com/anthropics/claude-code/issues/48511)
- [Desktop app needs multi-account support (#36821)](https://github.com/anthropics/claude-code/issues/36821)
- [Preserve conversation continuity when switching profiles, Team → Personal (#68441)](https://github.com/anthropics/claude-code/issues/68441)

Existing community tools ([claude-swap](https://github.com/realiti4/claude-swap) and various profile launchers) only address the **CLI** history layer or create fully *isolated* app instances. This tool is, as far as I know, the only one that shares the **desktop app's own chat list** across accounts on one machine.

## How it works

The desktop app stores one JSON file per chat:

```
%APPDATA%\Claude\claude-code-sessions\<device-id>\<workspace-id>\local_*.json
```

Each logged-in account gets its own `<device-id>` folder — that folder boundary *is* the account wall. The session files themselves carry no account binding, so mirroring them between the accounts' workspace folders makes every account show the same chat list.

A scheduled task (`ClaudeChatSync`) runs a sync every 5 minutes:

- **Newest-healthy-wins, per chat.** Renames and archive-status follow whichever account touched the chat last. A copy that the app's startup scanner has damaged (stripped `cliSessionId` / `transcriptUnavailable: true`, see [#63082](https://github.com/anthropics/claude-code/issues/63082)) never overwrites a healthy copy, regardless of timestamps.
- **Copy-only.** The sync never deletes anything. (Consequence: deleting a chat on one account resurrects it from the other — archive instead of deleting.)
- **Both data roots are watched** (`%APPDATA%\Claude` and `%LOCALAPPDATA%\Claude-3p`), so the app-internal migration path present in current builds won't silently break the sync.
- **Hardened task registration.** Windows Task Scheduler defaults would silently kill a naive setup: tasks don't start on battery by default, and a once-with-repetition trigger [dies after a reboot](https://learn.microsoft.com/en-us/troubleshoot/windows-server/system-management-components/scheduled-task-not-run-upon-reboot-machine-off). The installer registers the task with battery-safe settings, `StartWhenAvailable`, and a logon trigger carrying its own repetition.

The app reads the sessions folder **at startup** (it does not watch it live), so the flow is: switch account → app starts → your full list is there.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Registers the scheduled task, generates a hidden launcher, and runs a first sync. Requires no admin rights (per-user task).

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Removes the task and launcher. Your chat files are left exactly as they are.

## What this does NOT do

- **Connectors / MCP OAuth grants are not shared.** Those are bound to each Claude account server-side; no local tool can move them. Authorize connectors once per account.
- **Usage/quota is per account and stays per account.** This tool only mirrors local chat-list metadata; nothing server-side is touched or circumvented.
- **CLI history is out of scope** — the CLI (`claude --resume`) already reads its transcripts account-agnostically.

## Limitations

- Chats created less than ~5 minutes before an account switch may not have synced yet. Run `sync-claude-sessions.ps1` manually before switching, or restart the app a few minutes later.
- The app must be restarted to reflect changes made while it was open (startup-read, no live watch).
- Windows only.
- This relies on **undocumented internals** of the Claude desktop app (folder layout observed in v1.24012.x). Any update may change the storage format or location and break the sync — the app has [changed this layout before](https://github.com/anthropics/claude-code/issues/29373). Failure mode is benign: the sync simply stops finding files; it never deletes.

## Safety notes

- Local file copies only. No network access, no credentials read or written, nothing sent anywhere.
- The sync never deletes files; the worst-case failure is a stale list entry.
- Not affiliated with or endorsed by Anthropic. Use at your own risk.

## License

MIT
