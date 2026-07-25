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

Each logged-in account gets its own `<device-id>` folder — that folder boundary *is* the account wall. The session files themselves carry no account binding, so mirroring them between the accounts' workspace folders makes every account show the same chat list. (Observed layouts have exactly one workspace folder per account; chats from all your project directories share it. A device with several chat-bearing workspace folders is skipped with a logged warning rather than guessed at.)

A scheduled task (`ClaudeChatSync`) runs a sync every 5 minutes:

- **Newest-healthy-wins, per chat file.** Renames and archive-status follow whichever account touched the chat last. Health beats timestamps: a copy that the app's startup scanner has damaged (stripped `cliSessionId` / `transcriptUnavailable: true`, see [#63082](https://github.com/anthropics/claude-code/issues/63082)) never overwrites a healthy copy, and a healthy copy heals a damaged one even when the damaged one is newer. An unreadable (locked, mid-write) copy neither wins nor loses protection. Note this is per-file, not a field-level merge: if you rename a chat on one account and archive it on the other before a sync runs, the older of the two edits loses.
- **Atomic writes.** Every copy goes to a temp sibling, is verified (size + health), then renamed into place. The app can never observe a half-written session file.
- **Overwrites, never deletes.** The sync never deletes a file, but it does overwrite older versions with newer ones — that is its job. Chat *transcripts* live elsewhere (`~/.claude/projects/`) and are never touched; these files are list metadata (title, archive flag, model, working directory). The installer also takes a one-time zip backup of both session roots before the first sync. (Consequence of copy-only: deleting a chat on one account resurrects it from the other — archive instead of deleting.)
- **A fresh account is seeded.** A newly added account's empty workspace folder receives the shared list on the next run, before its first chat.
- **Both known data roots are checked** on every run (`%APPDATA%\Claude` and `%LOCALAPPDATA%\Claude-3p`, the migration target present in current app builds).
- **Every run writes a heartbeat** to `sync-log.txt`, so a silently dead sync is distinguishable from a quiet one. `sync-claude-sessions.ps1 -Status` prints roots/targets/last-run at a glance.
- **Concurrent runs are serialized** by a named mutex (scheduled task + manual run can't interleave), and the task is registered battery-safe and reboot-safe (Task Scheduler defaults would silently stop it on both — [battery](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-disallowstartifonbatteries), [reboot](https://learn.microsoft.com/en-us/troubleshoot/windows-server/system-management-components/scheduled-task-not-run-upon-reboot-machine-off)).

The app reads the sessions folder **at startup** (it does not watch it live), so the flow is: switch account → app starts → your full list is there.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer copies the sync script to `%LOCALAPPDATA%\ClaudeChatSync\` and registers the task against that copy — the repo clone stays a repo, and `git pull` can never silently change what the scheduled task executes. No admin rights required (per-user task). It refuses to replace a scheduled task it doesn't recognize as its own, and it verifies the first run by checking for a fresh heartbeat, not by trusting exit codes.

Preview what a sync would do without touching anything:

```powershell
powershell -File "$env:LOCALAPPDATA\ClaudeChatSync\sync-claude-sessions.ps1" -WhatIf
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Stops and removes the task and the installed script. Your chat files are left exactly as they are; the backup zip and log are deliberately kept in `%LOCALAPPDATA%\ClaudeChatSync\`.

## What this does NOT do

- **Connectors / MCP OAuth grants are not shared.** Those are bound to each Claude account server-side; no local tool can move them. Authorize connectors once per account.
- **Usage/quota is per account and stays per account.** This tool only mirrors local chat-list metadata; nothing server-side is touched or circumvented.
- **CLI history is out of scope** — the CLI (`claude --resume`) already reads its transcripts account-agnostically.

## Limitations

- Chats created less than ~5 minutes before an account switch may not have synced yet. Run the sync script manually before switching, or restart the app a few minutes later.
- The app must be restarted to reflect changes made while it was open (startup-read, no live watch).
- Windows only. Target runtime is Windows PowerShell 5.1 (the built-in `powershell.exe`).
- This relies on **undocumented internals** of the Claude desktop app (folder layout observed in v1.24012.x). Any update may change the storage format or location and break the sync — the app has [changed this layout before](https://github.com/anthropics/claude-code/issues/29373). The failure mode is a no-op, and you can see it: the heartbeat line will report 0 roots or 1 workspace.

## Safety notes

- Local file copies only. No network access, no credentials read or written, nothing sent anywhere.
- The sync overwrites older chat-list metadata with newer; it never deletes files, and a pre-first-sync backup zip exists in `%LOCALAPPDATA%\ClaudeChatSync\`.
- **Policy note for managed devices:** this tool copies chat metadata between accounts on your machine — including from a work account's folder to a personal account's folder. Under many employer acceptable-use/DLP policies that counts as moving corporate data, even though nothing leaves the device. Check your employer's policy before using it on a managed device.
- Not affiliated with or endorsed by Anthropic. Use at your own risk.

## Tests

```powershell
Invoke-Pester -Path tests    # requires Pester 5+
```

The suite runs the engine against fixture trees: cross-account propagation, fresh-account seeding, damaged-never-beats-healthy (and healing), locked-destination protection, multi-workspace device skip, and `-WhatIf` inertness.

## License

MIT
