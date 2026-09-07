# claude-desktop-session-sync

![tests](https://github.com/RasmusKD/claude-desktop-session-sync/actions/workflows/tests.yml/badge.svg)

Keep your Claude Code chat list, and its sidebar groups, when switching accounts in the **Claude desktop app** on Windows.

## The problem

The Claude desktop app scopes its chat/session list to the logged-in account. Switch accounts (work/personal, Team to Personal) and your sidebar goes empty. The chats still exist on disk, but the app only shows the current account's slice. This is a widely reported limitation with no official solution:

- [Desktop app: session history lost when switching accounts (#48511)](https://github.com/anthropics/claude-code/issues/48511)
- [Desktop app needs multi-account support (#36821)](https://github.com/anthropics/claude-code/issues/36821)
- [Preserve conversation continuity when switching profiles, Team to Personal (#68441)](https://github.com/anthropics/claude-code/issues/68441)

Existing community tools ([claude-swap](https://github.com/realiti4/claude-swap) and various profile launchers) only address the CLI history layer, or create fully isolated app instances. This tool is, as far as I know, the only one that shares the desktop app's own chat list across accounts on one machine.

## How it works

### Where the app keeps things (observed on Claude desktop 1.46388.4, MSIX build)

**Chat list.** One JSON file per chat:

```
%APPDATA%\Claude\claude-code-sessions\<account-uuid>\<org-uuid>\local_*.json
```

The first folder is the logged-in account, the second the organization it was using; that pair is the "scope key" (`<account>/<org>`) the app uses everywhere. The session files carry no account binding (their fields are things like `cliSessionId`, `cwd`, `title`, `titleSource`, `lastFocusedAt`, `worktreeName`, `worktreePath`, `bridgeSessionIds`; none names an account or org), so mirroring them between the accounts' folders makes every account show the same list. Observed layouts have exactly one org folder per account; chats from all your project directories share it. An account with several chat-bearing org folders is skipped with a logged warning rather than guessed at, because nothing in the files says which of its orgs should pair with the other account's.

**Sidebar groups.** Custom groups do NOT live in the session files and, since some build between 1.24 and 1.46, no longer live primarily in `claude_desktop_config.json` either. They live in the app's Electron Local Storage for the `https://claude.ai` origin:

```
%APPDATA%\Claude\Local Storage\leveldb\        (a LevelDB the app holds open while it runs)
```

Both accounts' groups sit in that one database (one Electron profile), under two keys:

- `dframe-store` (a zustand persist blob, `version: 1`): `state.customGroupsByScope` maps each scope key to `{ groups: [{ id: "cg-<uuid>", name }], assignments: { "code:local_<session>": "cg-<uuid>" }, order: { "cg-<uuid>": ["code:local_<session>", ...] } }`. The same blob holds `pinnedOrder`, `collapsedGroups` (`custom-<group id>`), `sidebarRowCountsByScope` and `lastSidebarScopeKey` (the scope the sidebar showed last).
- `LSS-persisted.dframe-group-scopes`: `{ value: <the same scope map>, tabId: "", timestamp: <ms> }`, the app's own mirror of the store slice.

No color field exists on groups in this build. `pinnedOrder` is global (not per scope), so pins are already shared between accounts and nothing needs to sync them.

`claude_desktop_config.json` -> `preferences.epitaxyPrefs.dframe-group-scopes` still holds a copy of that map, but the app writes it FROM Local Storage (every `LSS-persisted.*` key has a twin under `epitaxyPrefs`); it is an output, and treating it as the source, as this tool did until 0.5, silently reverted groups the app had already saved. The app also exposes the groups to Claude Code sessions running inside it through an MCP server named `ccd_sidebar` (`list_groups`, `create_group`, `rename_group`, `delete_group`, `move_sessions`, `set_pinned`, `set_unread`, `mark_completed`, `set_view`), gated "when available"; that is the app-supported way to change groups from inside a session and the future path for this tool if it ever becomes scriptable from outside a session. It is not reachable from a scheduled task today.

### The sync

A scheduled task (`ClaudeChatSync`) runs a sync every 5 minutes:

- **Newest-healthy-wins, per chat file.** Renames and archive-status follow whichever account touched the chat last. Health beats timestamps: a copy that the app's startup scanner has damaged (stripped `cliSessionId` / `transcriptUnavailable: true`, see [#63082](https://github.com/anthropics/claude-code/issues/63082)) never overwrites a healthy copy, and a healthy copy heals a damaged one even when the damaged one is newer. An unreadable (locked, mid-write) copy neither wins nor loses protection. Note this is per-file, not a field-level merge: if you rename a chat on one account and archive it on the other before a sync runs, the older of the two edits loses.
- **Atomic writes.** Every copy goes to a temp sibling, is verified (size + health), then renamed into place. The app can never observe a half-written session file.
- **Overwrites and deletions are mirrored, with a safety net.** Newer chat-list metadata overwrites older; that is the job. Deleting a chat on one account deletes it on the others too, tracked via a timestamped manifest of fully-synced chats so a deletion is never confused with a not-yet-synced new chat (a manifest older than 7 days is discarded and rebuilt, never trusted). Before a propagated deletion, the best surviving copy is stashed in `%LOCALAPPDATA%\ClaudeChatSync\deleted\` (named with its source account, kept 30 days), and the installer zips both session roots (and the Local Storage database) on first install and on every version upgrade. A deletion that partially fails (a copy held open by the app) is retried on the next run instead of being silently undone. Restore a stashed chat everywhere with `sync-claude-sessions.ps1 -Restore <name>`. Chat *transcripts* live elsewhere (`~/.claude/projects/`) and are never touched; these files are list metadata (title, archive flag, model, working directory).
- **Sidebar groups are merged three-way, only while the app is closed.** The group stage is a small Node.js helper (`group-sync\group-sync.mjs`) that opens the Local Storage database with a real LevelDB implementation (`classic-level`), never by byte-splicing. It merges every synced account's scope entry against the last synced result (kept in `groups-base.json`): a group that a previously synced account no longer has is a deletion and propagates; a group the base never held is an addition and propagates; a rename propagates from the side that changed it; an account the base has never seen (a new account, or one whose storage the app wiped) contributes additions only. Without a base nothing is ever deleted, so the first run after install is a plain union. Ties (both sides changed the same thing) go to the account the sidebar showed last. The merged entry is written to both Local Storage keys, the database's size accounting is updated, and the config-file copy is then rewritten the way the app writes it (a raw splice: every byte outside that one value survives verbatim, the file is parse-validated before and after, the write is atomic, and a concurrent change by the app makes the sync skip and retry). The app holds the database's lock while it runs, so the helper can only get in when the app is closed; a locked database is reported as `groups deferred`, never as success. The flow is therefore: close the app, let a sync run (or run it yourself), start the app.
- **Backup-first, everywhere.** Before the helper opens the database for a write it copies the whole LevelDB directory into `%LOCALAPPDATA%\ClaudeChatSync\leveldb-backup-<stamp>\` (five kept); before it touches the config it copies that too (`config-backup-<stamp>.json`, five kept).
- **A fresh account is seeded.** A newly added account's empty workspace folder receives the shared list on the next run, before its first chat. An empty workspace is never treated as deletion evidence, and an account that held chats last run but is suddenly empty is **frozen**: recorded persistently (`frozen.txt`, survives reinstalls), excluded from seeding and deletion evidence while the rest of the sync continues. It thaws automatically when it gains a chat again (it is then reseeded; its pre-freeze clear-out is never applied as deletions) or explicitly via `-Unfreeze '<account>/<org>'`.
- **Both known data roots are checked** on every run (`%APPDATA%\Claude` and `%LOCALAPPDATA%\Claude-3p`, the migration target present in current app builds); when both hold accounts, only the most recently active root is synced, so a mid-migration abandoned root is never repopulated.
- **Every run writes a heartbeat** to `%LOCALAPPDATA%\ClaudeChatSync\sync-log.txt` (rolling, last 1000 lines), ending in the group stage's state: `groups updated | unchanged | mirrored | deferred | would-update | off | error`. A silently dead sync is therefore distinguishable from a quiet one. `sync-claude-sessions.ps1 -Status` prints roots, targets, group-sync state, the log path and the last heartbeats.
- **Concurrent runs are serialized** by a lock file (scheduled task + manual run can't interleave, even across logon sessions), and the task is registered battery-safe and reboot-safe. Task Scheduler defaults would silently stop it on both counts: see the Microsoft docs on [battery conditions](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-disallowstartifonbatteries) and [missed-start behavior](https://learn.microsoft.com/en-us/troubleshoot/windows-server/system-management-components/scheduled-task-not-run-upon-reboot-machine-off).

The app reads the sessions folder **at startup** (it does not watch it live), so the flow is: switch account, app starts, your full list is there. Groups need the app closed for one sync (see above).

### Do not run or inspect this from inside the Claude desktop app

A Claude Code session started by the desktop app is an MSIX-packaged process, and the shells it spawns get MSIX file-system virtualization: their writes under `%LOCALAPPDATA%` are redirected into `%LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Local\...`, and their reads show a merged view in which those redirected files shadow the real ones. An `install.ps1` run from such a session installs into that shadow (the scheduled task never runs it), and from then on every look from inside the app shows the shadow's stale script and dead log while the real task keeps running fine underneath. Nothing in the process identity APIs reports this, so the tool probes for it: it writes a file into its state directory and checks whether a package mirror shows it. The engine refuses to run when it sees a shadow (exit code 2, with the real path printed), `-Status` says so in red, and `install.ps1`/`uninstall.ps1` refuse too; an install from a normal terminal moves any stale shadow aside.

## Install

```powershell
git clone https://github.com/RasmusKD/claude-desktop-session-sync
cd claude-desktop-session-sync
powershell -ExecutionPolicy Bypass -File install.ps1
```

(No git? Download the ZIP from GitHub, extract it, and run the last line from the extracted folder. Use a normal terminal, not a Claude Code session inside the desktop app; see above.)

The installer copies the engine (`sync-claude-sessions.ps1`, `common.ps1`, `group-sync\`) to `%LOCALAPPDATA%\ClaudeChatSync\` and registers the task against that copy, so the repo clone stays a repo and `git pull` can never silently change what the scheduled task executes. No admin rights required (per-user task). It refuses to replace a scheduled task it doesn't recognize as its own, and it verifies the first run by checking for a fresh heartbeat, not by trusting exit codes.

**Group sync needs Node.js** (18 or newer, [nodejs.org](https://nodejs.org)) on `PATH`: the installer runs `npm ci` in the installed `group-sync\` folder to fetch its one dependency (`classic-level`, pinned in `package-lock.json`, prebuilt for Windows x64, no compiler needed). Without Node.js the chat list still syncs and the heartbeat ends in `groups off`; install Node.js and re-run `install.ps1` to enable it. The trade taken: the chat sync stays dependency-free (Windows PowerShell 5.1 only), and the one feature that needs a real database engine pays for one npm package instead of a hand-rolled LevelDB writer that could corrupt the app's storage.

Preview what a sync would do without touching anything (groups included, reported as `groups would-update` when a merge is pending):

```powershell
powershell -File "$env:LOCALAPPDATA\ClaudeChatSync\sync-claude-sessions.ps1" -WhatIf
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Stops and removes the task and the installed files, and tells you exactly what stays behind (backups, config copies, Local Storage snapshots, the deletion stash, the freeze list). Your chat files and the app's Local Storage are left exactly as they are. `uninstall.ps1 -Purge` deletes the kept data too.

## What this does NOT do

- **Regular claude.ai ("Home") conversations are not synced.** Those are stored server-side in each Claude account; the desktop app only displays them from the cloud. There is no local file to mirror, so no local tool can share them across accounts. Only Claude Code sessions have local files.
- **Connectors / MCP OAuth grants are not shared.** Those are bound to each Claude account server-side; no local tool can move them. Authorize connectors once per account.
- **Usage/quota is per account and stays per account.** This tool only mirrors local chat-list metadata; nothing server-side is touched or circumvented.
- **CLI history is out of scope.** The CLI (`claude --resume`) already reads its transcripts account-agnostically.

## Limitations

- Chats created less than ~5 minutes before an account switch may not have synced yet. Run the sync script manually before switching, or restart the app a few minutes later.
- Groups only merge while the app is closed (the app holds the database lock). Group changes made on one account become visible on the other after: close the app, one sync, start the app. While the app runs every heartbeat says `groups deferred`; that is expected.
- The helper holds the database lock for a fraction of a second. Starting the app inside that window would make the app find its storage locked; the process pre-check makes this a startup-race of milliseconds, not something the schedule can hit while the app is already running.
- A chat deletion wins over an edit made to the same chat on another account since the last sync (the deletion propagates; the healthiest, newest surviving copy is what lands in the `deleted\` stash). Likewise a group deleted on one account wins over a rename of the same group on the other.
- Emptying an account entirely freezes it out of the sync (see above); it stays frozen until it gains a chat again or you run `-Unfreeze`. This is deliberate, because both mass-reseed and mass-delete are wrong guesses about what you meant.
- Two timestamps within 2 seconds of each other count as equal (filesystem granularity); with equal sizes such copies are treated as identical.
- Persistent failure states escalate to marker files in the state dir (`GROUP-SYNC-BROKEN.txt` after three failed group runs, `SYNC-LOCK-STUCK.txt`); `-Status` prints them in red. `-Restore list` shows the deletion stash.
- `-RootsOverride`, `-ConfigPathOverride`, `-StateDirOverride`, `-LevelDbPathOverride`, `-GroupHelperOverride` and `-PackagesRootOverride` exist for the test suite and are unsupported for any other use. A run with `-RootsOverride` never touches the real Local Storage or config unless the matching override is given too.
- The app must be restarted to reflect changes made while it was open (startup-read, no live watch).
- Windows only. The scheduled task runs on Windows PowerShell 5.1 (the built-in `powershell.exe`, present on every Windows machine); group sync additionally needs Node.js. The scripts are also verified against PowerShell 7 (test suite passes on both 5.1 and 7.6), so you can run or test them under `pwsh` too.
- This relies on **undocumented internals** of the Claude desktop app (folder layout and Local Storage keys observed in 1.46388.4; the config-file location of groups observed in 1.24012.x is gone). Any update may change the storage format or location and break the sync; the app has [changed this layout before](https://github.com/anthropics/claude-code/issues/29373). The failure mode is a no-op, and you can see it: the heartbeat line will report 0 roots, 1 workspace, or `groups off`/`groups error`.

## Safety notes

- Local file operations only. No network access after `npm ci` at install time; nothing is sent anywhere.
- **This tool deletes files by design** (that is what deletion propagation is), with three nets: the pre-deletion stash in `deleted\` (30 days), the install/upgrade backup zips, and the 7-day manifest trust window. It also keeps up to five rotating backups of `claude_desktop_config.json` and five snapshots of the app's Local Storage database in `%LOCALAPPDATA%\ClaudeChatSync\`; the config can contain MCP server definitions, which sometimes hold API keys, and the Local Storage holds the app's per-account browser state, so treat that folder as sensitive and delete it on uninstall if you don't want the copies.
- **Policy note for managed devices:** this tool copies chat metadata between accounts on your machine, including from a work account's folder to a personal account's folder. Under many employer acceptable-use/DLP policies that counts as moving corporate data, even though nothing leaves the device. Check your employer's policy before using it on a managed device.
- Not affiliated with or endorsed by Anthropic. Use at your own risk.

## Tests

```powershell
cd group-sync; npm ci; cd ..    # once, for the group-sync tests (skipped with a warning without it)
Invoke-Pester -Path tests       # requires Pester 5+
```

The suite runs the engine against fixture trees and fixture Local Storage databases (built by `tests\leveldb-fixture.mjs` with the same LevelDB library): cross-account propagation, fresh-account seeding, damaged-never-beats-healthy (and healing), locked-destination protection, multi-workspace device skip, deletion propagation with its fresh-account guard, the three-way group merge (propagation, deletion plus rename, first-run union, a wiped scope as seed target), the app-holds-the-lock refusal, config-mirror byte fidelity with BOM and decoy anchors, the MSIX shadow refusal, and `-WhatIf` inertness. CI runs it on Windows PowerShell 5.1 and PowerShell 7, under invariant and tr-TR/th-TH cultures, and fails on skipped tests.

## License

MIT
