# claude-desktop-session-sync

![tests](https://github.com/RasmusKD/claude-desktop-session-sync/actions/workflows/tests.yml/badge.svg)

Keep your Claude Code chat list when switching accounts in the **Claude desktop app** on Windows.

## The problem

The Claude desktop app scopes its chat/session list to the logged-in account. Switch accounts (work/personal, Team to Personal) and your sidebar goes empty. The chats still exist on disk, but the app only shows the current account's slice. This is a widely reported limitation with no official solution:

- [Desktop app: session history lost when switching accounts (#48511)](https://github.com/anthropics/claude-code/issues/48511)
- [Desktop app needs multi-account support (#36821)](https://github.com/anthropics/claude-code/issues/36821)
- [Preserve conversation continuity when switching profiles, Team to Personal (#68441)](https://github.com/anthropics/claude-code/issues/68441)

Existing community tools ([claude-swap](https://github.com/realiti4/claude-swap) and various profile launchers) only address the CLI history layer, or create fully isolated app instances. This tool is, as far as I know, the only one that shares the desktop app's own chat list across accounts on one machine.

## How it works

The desktop app stores one JSON file per chat:

```
%APPDATA%\Claude\claude-code-sessions\<device-id>\<workspace-id>\local_*.json
```

Each logged-in account gets its own `<device-id>` folder, and that folder boundary is the account wall. The session files themselves carry no account binding, so mirroring them between the accounts' workspace folders makes every account show the same chat list. (Observed layouts have exactly one workspace folder per account; chats from all your project directories share it. A device with several chat-bearing workspace folders is skipped with a logged warning rather than guessed at.)

A scheduled task (`ClaudeChatSync`) runs a sync every 5 minutes:

- **Newest-healthy-wins, per chat file.** Renames and archive-status follow whichever account touched the chat last. Health beats timestamps: a copy that the app's startup scanner has damaged (stripped `cliSessionId` / `transcriptUnavailable: true`, see [#63082](https://github.com/anthropics/claude-code/issues/63082)) never overwrites a healthy copy, and a healthy copy heals a damaged one even when the damaged one is newer. An unreadable (locked, mid-write) copy neither wins nor loses protection. Note this is per-file, not a field-level merge: if you rename a chat on one account and archive it on the other before a sync runs, the older of the two edits loses.
- **Atomic writes.** Every copy goes to a temp sibling, is verified (size + health), then renamed into place. The app can never observe a half-written session file.
- **Overwrites and deletions are mirrored, with a safety net.** Newer chat-list metadata overwrites older; that is the job. Deleting a chat on one account deletes it on the others too, tracked via a timestamped manifest of fully-synced chats so a deletion is never confused with a not-yet-synced new chat (a manifest older than 7 days is discarded and rebuilt, never trusted). Before a propagated deletion, the best surviving copy is stashed in `%LOCALAPPDATA%\ClaudeChatSync\deleted\` (named with its source account, kept 30 days), and the installer zips both session roots on first install and on every version upgrade. A deletion that partially fails (a copy held open by the app) is retried on the next run instead of being silently undone. Restore a stashed chat everywhere with `sync-claude-sessions.ps1 -Restore <name>`. Chat *transcripts* live elsewhere (`~/.claude/projects/`) and are never touched; these files are list metadata (title, archive flag, model, working directory).
- **Sidebar groups follow you (last-writer-wins).** Group state lives account-keyed in `claude_desktop_config.json`. The sync copies the most recently active account's entry onto the others as a **raw text splice**: the config file is never parsed-and-reserialized, so every byte outside the spliced keys (dates, single-element arrays, properties this tool has never heard of) survives verbatim. Group renames and deletions propagate like everything else. Writes are atomic, guarded against the app writing concurrently (skip and retry rather than clobber), happen only on change, and the five most recent config backups are kept.
- **A fresh account is seeded.** A newly added account's empty workspace folder receives the shared list on the next run, before its first chat. An empty workspace is never treated as deletion evidence, and an account that held chats last run but is suddenly empty is **frozen** (neither reseeded nor used as deletion evidence) so an intentional clear-out and an app reset both stay contained.
- **Both known data roots are checked** on every run (`%APPDATA%\Claude` and `%LOCALAPPDATA%\Claude-3p`, the migration target present in current app builds).
- **Every run writes a heartbeat** to `sync-log.txt`, so a silently dead sync is distinguishable from a quiet one. `sync-claude-sessions.ps1 -Status` prints roots/targets/last-run at a glance.
- **Concurrent runs are serialized** by a named mutex (scheduled task + manual run can't interleave), and the task is registered battery-safe and reboot-safe. Task Scheduler defaults would silently stop it on both counts: see the Microsoft docs on [battery conditions](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-disallowstartifonbatteries) and [missed-start behavior](https://learn.microsoft.com/en-us/troubleshoot/windows-server/system-management-components/scheduled-task-not-run-upon-reboot-machine-off).

The app reads the sessions folder **at startup** (it does not watch it live), so the flow is: switch account, app starts, your full list is there.

## Install

```powershell
git clone https://github.com/RasmusKD/claude-desktop-session-sync
cd claude-desktop-session-sync
powershell -ExecutionPolicy Bypass -File install.ps1
```

(No git? Download the ZIP from GitHub, extract it, and run the last line from the extracted folder.)

The installer copies the sync script to `%LOCALAPPDATA%\ClaudeChatSync\` and registers the task against that copy, so the repo clone stays a repo and `git pull` can never silently change what the scheduled task executes. No admin rights required (per-user task). It refuses to replace a scheduled task it doesn't recognize as its own, and it verifies the first run by checking for a fresh heartbeat, not by trusting exit codes.

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

- **Regular claude.ai ("Home") conversations are not synced.** Those are stored server-side in each Claude account; the desktop app only displays them from the cloud. There is no local file to mirror, so no local tool can share them across accounts. Only Claude Code sessions have local files.
- **Connectors / MCP OAuth grants are not shared.** Those are bound to each Claude account server-side; no local tool can move them. Authorize connectors once per account.
- **Usage/quota is per account and stays per account.** This tool only mirrors local chat-list metadata; nothing server-side is touched or circumvented.
- **CLI history is out of scope.** The CLI (`claude --resume`) already reads its transcripts account-agnostically.

## Limitations

- Chats created less than ~5 minutes before an account switch may not have synced yet. Run the sync script manually before switching, or restart the app a few minutes later.
- A chat deletion wins over an edit made to the same chat on another account since the last sync (the deletion propagates; the healthiest, newest surviving copy is what lands in the `deleted\` stash).
- Group sync is last-writer-wins per account entry: whichever account was active most recently defines the group list for all accounts. Concurrent group edits on two accounts between syncs lose the older side.
- Emptying an account entirely freezes it out of the sync (see above) until the manifest's 7-day window expires or you delete the manifest (`sync-fullset.txt`); this is deliberate, because both mass-reseed and mass-delete are wrong guesses about what you meant.
- The app must be restarted to reflect changes made while it was open (startup-read, no live watch).
- Windows only. The scheduled task runs on Windows PowerShell 5.1 (the built-in `powershell.exe`, present on every Windows machine, so the tool has zero install dependencies). The scripts are also verified against PowerShell 7 (test suite passes on both 5.1 and 7.6), so you can run or test them under `pwsh` too.
- This relies on **undocumented internals** of the Claude desktop app (folder layout observed in v1.24012.x). Any update may change the storage format or location and break the sync; the app has [changed this layout before](https://github.com/anthropics/claude-code/issues/29373). The failure mode is a no-op, and you can see it: the heartbeat line will report 0 roots or 1 workspace.

## Safety notes

- Local file operations only. No network access; nothing is sent anywhere.
- **This tool deletes files by design** (that is what deletion propagation is), with three nets: the pre-deletion stash in `deleted\` (30 days), the install/upgrade backup zips, and the 7-day manifest trust window. It also reads and keeps up to five rotating backups of `claude_desktop_config.json` in `%LOCALAPPDATA%\ClaudeChatSync\`; that file can contain MCP server definitions, which sometimes hold API keys, so treat that folder as sensitive and delete it on uninstall if you don't want the copies.
- **Policy note for managed devices:** this tool copies chat metadata between accounts on your machine, including from a work account's folder to a personal account's folder. Under many employer acceptable-use/DLP policies that counts as moving corporate data, even though nothing leaves the device. Check your employer's policy before using it on a managed device.
- Not affiliated with or endorsed by Anthropic. Use at your own risk.

## Tests

```powershell
Invoke-Pester -Path tests    # requires Pester 5+
```

The suite runs the engine against fixture trees: cross-account propagation, fresh-account seeding, damaged-never-beats-healthy (and healing), locked-destination protection, multi-workspace device skip, deletion propagation with its fresh-account guard, sidebar-group mirroring, and `-WhatIf` inertness.

## License

MIT
