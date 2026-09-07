// Sidebar-group sync for the Claude desktop app: three-way merge of the
// per-account custom-group scopes that live in the app's Electron Local Storage
// (a LevelDB the app holds open while it runs), plus the config-file mirror the
// app keeps of the same value. Invoked by sync-claude-sessions.ps1; see README.
//
// Invariants:
//  - the LevelDB is opened with a real LevelDB implementation, never byte-spliced,
//    and only when the app is not running: the app's own LOCK refuses us
//    otherwise, and that refusal is reported as "deferred", never as success.
//  - backup-first: the LevelDB directory is copied BEFORE it is opened for a
//    write, and the config file is copied before it is spliced.
//  - the merge is three-way against the last synced result (the base): a group
//    that is absent from a scope which was synced before is a deletion, a group
//    the base never held is an addition, and a scope the base never saw (a new
//    account, or one the app wiped) contributes additions only. Without a base
//    nothing is ever deleted.
//  - the config mirror is an OUTPUT only. The app writes it from Local Storage,
//    so reading it back as evidence would resurrect whatever the app last
//    flushed; every byte outside the spliced value survives verbatim.
import { ClassicLevel } from 'classic-level';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const ORIGIN = 'https://claude.ai';
const SCOPES_KEY = 'LSS-persisted.dframe-group-scopes';
const STORE_KEY = 'dframe-store';
const CONFIG_PATH = ['preferences', 'epitaxyPrefs', 'dframe-group-scopes'];
const LEVELDB_BACKUPS_KEPT = 5;
const CONFIG_BACKUPS_KEPT = 5;

// ── CLI ──────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const out = { dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === '--leveldb') out.leveldb = next();
    else if (a === '--config') out.config = next();
    else if (a === '--state') out.state = next();
    else if (a === '--scopes') out.scopes = next();
    else if (a === '--dry-run') out.dryRun = true;
    else throw new Error(`unknown argument ${a}`);
  }
  for (const k of ['leveldb', 'state', 'scopes']) if (!out[k]) throw new Error(`--${k} is required`);
  out.scopes = out.scopes.split(';').filter(Boolean);
  if (out.scopes.length < 2) throw new Error('--scopes needs at least two scope keys');
  return out;
}

// ── Chromium Local Storage encoding ──────────────────────────────────────────
// Map entries: key = "_" + origin + "\0" + (0x00 + UTF-16LE | 0x01 + Latin-1);
// value = (0x00 + UTF-16LE | 0x01 + Latin-1). "META:" + origin holds a protobuf
// {1: last_modified (microseconds since 1601), 2: size_bytes} where size is the
// byte length of every key (after the origin prefix) plus every value.
const WINDOWS_EPOCH_OFFSET_US = 11644473600000000n;

function decodeString(buf) {
  if (buf.length === 0) return '';
  if (buf[0] === 0x00) return buf.subarray(1).toString('utf16le');
  if (buf[0] === 0x01) return buf.subarray(1).toString('latin1');
  throw new Error(`unknown string format byte 0x${buf[0].toString(16)}`);
}

function encodeString(s) {
  let latin1 = true;
  for (let i = 0; i < s.length; i++) if (s.charCodeAt(i) > 0xff) { latin1 = false; break; }
  return latin1
    ? Buffer.concat([Buffer.from([0x01]), Buffer.from(s, 'latin1')])
    : Buffer.concat([Buffer.from([0x00]), Buffer.from(s, 'utf16le')]);
}

function mapKeyPrefix(origin) { return Buffer.from(`_${origin}\0`, 'latin1'); }

function decodeVarint(buf, pos) {
  let result = 0n; let shift = 0n;
  for (;;) {
    const b = buf[pos++];
    result |= BigInt(b & 0x7f) << shift;
    if ((b & 0x80) === 0) return [result, pos];
    shift += 7n;
  }
}

function encodeVarint(n) {
  const bytes = [];
  let v = BigInt(n);
  do { let b = Number(v & 0x7fn); v >>= 7n; if (v > 0n) b |= 0x80; bytes.push(b); } while (v > 0n);
  return Buffer.from(bytes);
}

function decodeMeta(buf) {
  const meta = { lastModifiedUs: 0n, sizeBytes: 0n };
  let pos = 0;
  while (pos < buf.length) {
    const tag = buf[pos++];
    const [val, next] = decodeVarint(buf, pos);
    pos = next;
    if (tag === 0x08) meta.lastModifiedUs = val;
    else if (tag === 0x10) meta.sizeBytes = val;
  }
  return meta;
}

function encodeMeta(meta) {
  return Buffer.concat([Buffer.from([0x08]), encodeVarint(meta.lastModifiedUs), Buffer.from([0x10]), encodeVarint(meta.sizeBytes)]);
}

async function readOrigin(db, origin) {
  const prefix = mapKeyPrefix(origin);
  const entries = new Map(); // name -> { key: Buffer, value: Buffer }
  let sizeBytes = 0;
  for await (const [k, v] of db.iterator({ gte: prefix, lt: Buffer.concat([prefix, Buffer.from([0xff])]) })) {
    const name = decodeString(k.subarray(prefix.length));
    entries.set(name, { key: k, value: v });
    sizeBytes += (k.length - prefix.length) + v.length;
  }
  const metaKey = Buffer.from(`META:${origin}`, 'latin1');
  let meta = null;
  try { meta = decodeMeta(await db.get(metaKey)); } catch (e) { if (e.code !== 'LEVEL_NOT_FOUND') throw e; }
  return { prefix, entries, sizeBytes, metaKey, meta };
}

// ── Three-way merge ──────────────────────────────────────────────────────────
const emptyEntry = () => ({ groups: [], assignments: {}, order: {} });

function normalizeEntry(e) {
  const out = { ...(e && typeof e === 'object' ? e : {}) };
  out.groups = Array.isArray(out.groups) ? out.groups.filter((g) => g && typeof g.id === 'string') : [];
  out.assignments = out.assignments && typeof out.assignments === 'object' && !Array.isArray(out.assignments) ? { ...out.assignments } : {};
  out.order = out.order && typeof out.order === 'object' && !Array.isArray(out.order) ? { ...out.order } : {};
  return out;
}

// Key order is not content: the app and the fixtures serialize the same entry
// with different property orders, and a merge that "changed" nothing must say so.
function canon(v) {
  if (Array.isArray(v)) return v.map(canon);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])]));
  return v;
}
const deepEqual = (a, b) => JSON.stringify(canon(a)) === JSON.stringify(canon(b));
const uniq = (xs) => [...new Set(xs)];

// scopes: the keys to equalize. present: scope -> entry actually found in Local
// Storage (absent scopes are seed targets). base: { scopes, entry } from the last
// sync, or null. prefer: scope order used to break ties (most recent first).
export function mergeScopes(scopes, present, base, prefer) {
  const pref = uniq([...prefer.filter((s) => scopes.includes(s)), ...scopes]);
  const b = normalizeEntry(base ? base.entry : null);
  const baseScopes = new Set(base ? base.scopes : []);
  const cur = {};
  for (const s of pref) if (present[s]) cur[s] = normalizeEntry(present[s]);
  const presentScopes = pref.filter((s) => cur[s]);
  // Deletion evidence comes only from scopes that were synced before AND are
  // present now: a newcomer or a wiped scope cannot "lack" anything.
  const evidence = presentScopes.filter((s) => baseScopes.has(s));
  const changes = { groupsAdded: [], groupsRemoved: [], groupsChanged: [], assignmentsChanged: 0 };

  const baseGroups = new Map(b.groups.map((g) => [g.id, g]));
  const ids = uniq([...b.groups.map((g) => g.id), ...presentScopes.flatMap((s) => cur[s].groups.map((g) => g.id))]);
  const merged = new Map();
  for (const id of ids) {
    const inBase = baseGroups.get(id);
    const holders = presentScopes.filter((s) => cur[s].groups.some((g) => g.id === id));
    if (inBase) {
      if (evidence.some((s) => !holders.includes(s))) { changes.groupsRemoved.push(id); continue; }
      const changed = holders.map((s) => cur[s].groups.find((g) => g.id === id)).find((g) => !deepEqual(g, inBase));
      if (changed) changes.groupsChanged.push(id);
      merged.set(id, changed ?? inBase);
    } else if (holders.length > 0) {
      changes.groupsAdded.push(id);
      merged.set(id, cur[holders[0]].groups.find((g) => g.id === id));
    }
  }
  // Group list order: the first preferred scope whose sequence departs from the
  // base decides; ids it does not know are appended in preference order.
  const baseSeq = b.groups.map((g) => g.id);
  let seq = baseSeq;
  for (const s of presentScopes) {
    const sSeq = cur[s].groups.map((g) => g.id);
    if (!deepEqual(sSeq, baseSeq)) { seq = sSeq; break; }
  }
  const groupOrder = uniq([...seq, ...presentScopes.flatMap((s) => cur[s].groups.map((g) => g.id))]).filter((id) => merged.has(id));
  const groups = groupOrder.map((id) => merged.get(id));

  const assignments = {};
  const aKeys = uniq([...Object.keys(b.assignments), ...presentScopes.flatMap((s) => Object.keys(cur[s].assignments))]);
  for (const key of aKeys) {
    const baseVal = b.assignments[key];
    let val;
    if (baseVal !== undefined) {
      const mover = presentScopes.find((s) => cur[s].assignments[key] !== baseVal && (holdsKey(cur[s], key) || evidence.includes(s)));
      val = mover ? cur[mover].assignments[key] : baseVal;
    } else {
      const adder = presentScopes.find((s) => cur[s].assignments[key] !== undefined);
      val = adder ? cur[adder].assignments[key] : undefined;
    }
    if (val !== undefined && merged.has(val)) assignments[key] = val;
    if (val !== baseVal) changes.assignmentsChanged++;
  }

  const order = {};
  for (const id of groupOrder) {
    const baseList = Array.isArray(b.order[id]) ? b.order[id] : [];
    let list = baseList;
    for (const s of presentScopes) {
      const sList = Array.isArray(cur[s].order[id]) ? cur[s].order[id] : null;
      if (sList && !deepEqual(sList, baseList)) { list = sList; break; }
    }
    const members = Object.keys(assignments).filter((k) => assignments[k] === id);
    const fromScopes = presentScopes.flatMap((s) => (Array.isArray(cur[s].order[id]) ? cur[s].order[id] : []));
    const merged = uniq([...list, ...fromScopes, ...members]).filter((k) => assignments[k] === id);
    // An order key nobody wrote is not invented: an empty list the app never
    // stored would read as a change on every run.
    const known = Object.prototype.hasOwnProperty.call(b.order, id) || presentScopes.some((s) => Object.prototype.hasOwnProperty.call(cur[s].order, id));
    if (merged.length > 0 || known) order[id] = merged;
  }

  // Unknown top-level fields ride along from the most recently active holder so
  // a future app field is never silently dropped from the scope we rewrite.
  const extras = {};
  for (const s of [...presentScopes].reverse()) {
    for (const [k, v] of Object.entries(cur[s])) if (!['groups', 'assignments', 'order'].includes(k)) extras[k] = v;
  }
  return { entry: { ...extras, groups, assignments, order }, changes };
}

function holdsKey(entry, key) { return Object.prototype.hasOwnProperty.call(entry.assignments, key); }

// ── Config mirror: raw-text splice with a root walk ──────────────────────────
// A tokenizer walk from the document root, never a regex anchor: a decoy
// occurrence of the key elsewhere in the file is never matched.
function skipWs(s, i) { while (i < s.length && /\s/.test(s[i])) i++; return i; }

function skipValue(s, i) {
  i = skipWs(s, i);
  if (i >= s.length) return -1;
  const c = s[i];
  if (c === '"') {
    i++;
    while (i < s.length) {
      if (s[i] === '\\') { i += 2; continue; }
      if (s[i] === '"') return i + 1;
      i++;
    }
    return -1;
  }
  if (c === '{' || c === '[') {
    const open = c; const close = c === '{' ? '}' : ']';
    let depth = 0;
    while (i < s.length) {
      const ch = s[i];
      if (ch === '"') { i = skipValue(s, i); if (i < 0) return -1; continue; }
      if (ch === open) depth++;
      else if (ch === close) { depth--; if (depth === 0) return i + 1; }
      i++;
    }
    return -1;
  }
  while (i < s.length && !/[,\]}\s]/.test(s[i])) i++;
  return i;
}

function findKeySpan(s, objStart, key) {
  let i = objStart + 1;
  while (i < s.length) {
    while (i < s.length && /[\s,]/.test(s[i])) i++;
    if (i >= s.length || s[i] === '}') return null;
    if (s[i] !== '"') return null;
    const kEnd = skipValue(s, i);
    if (kEnd < 0) return null;
    let k;
    try { k = JSON.parse(s.slice(i, kEnd)); } catch { return null; }
    let j = skipWs(s, kEnd);
    if (s[j] !== ':') return null;
    j = skipWs(s, j + 1);
    const vEnd = skipValue(s, j);
    if (vEnd < 0) return null;
    if (k === key) return { keyStart: i, valueStart: j, valueEnd: vEnd };
    i = vEnd;
  }
  return null;
}

function resolveValueSpan(s, pathKeys) {
  let objStart = s.indexOf('{');
  if (objStart < 0) return null;
  let span = null;
  for (const p of pathKeys) {
    span = findKeySpan(s, objStart, p);
    if (!span) return null;
    objStart = span.valueStart;
    if (p !== pathKeys[pathKeys.length - 1] && s[objStart] !== '{') return null;
  }
  return span;
}

function renderForConfig(text, span, value) {
  const lineStart = text.lastIndexOf('\n', span.keyStart) + 1;
  const indent = text.slice(lineStart, span.keyStart);
  if (!/^[ \t]*$/.test(indent) || lineStart === 0) return JSON.stringify(value);
  return JSON.stringify(value, null, 2).split('\n').map((l, i) => (i === 0 ? l : indent + l)).join('\n');
}

async function spliceConfig(configPath, stateDir, value, dryRun, warnings) {
  let raw;
  try { raw = await fs.readFile(configPath); } catch (e) { if (e.code === 'ENOENT') return 'missing'; throw e; }
  const hadBom = raw.length >= 3 && raw[0] === 0xef && raw[1] === 0xbb && raw[2] === 0xbf;
  const text = raw.toString('utf8').replace(/^﻿/, '');
  try { JSON.parse(text); } catch { warnings.push('config is not valid JSON; mirror skipped'); return 'skipped'; }
  const span = resolveValueSpan(text, CONFIG_PATH);
  if (!span) return 'missing-key';
  const before = text.slice(span.valueStart, span.valueEnd);
  const rendered = renderForConfig(text, span, value);
  if (before === rendered) return 'unchanged';
  let currentValue;
  try { currentValue = JSON.parse(before); } catch { currentValue = undefined; }
  if (currentValue !== undefined && deepEqual(currentValue, value)) return 'unchanged';
  const out = text.slice(0, span.valueStart) + rendered + text.slice(span.valueEnd);
  try { JSON.parse(out); } catch { warnings.push('config splice produced invalid JSON; write aborted'); return 'error'; }
  if (dryRun) return 'would-update';
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, '').replace('T', '-');
  await fs.copyFile(configPath, path.join(stateDir, `config-backup-${stamp}.json`));
  await rotate(stateDir, /^config-backup-.*\.json$/, CONFIG_BACKUPS_KEPT);
  const tmp = `${configPath}.cs-tmp-${process.pid}`;
  const bytes = Buffer.concat([hadBom ? Buffer.from([0xef, 0xbb, 0xbf]) : Buffer.alloc(0), Buffer.from(out, 'utf8')]);
  await fs.writeFile(tmp, bytes);
  // Lost-update guard: the app rewrites this file on its own schedule.
  const again = await fs.readFile(configPath);
  if (!again.equals(raw)) { await fs.rm(tmp, { force: true }); warnings.push('config changed under us; mirror retried next run'); return 'skipped'; }
  await fs.rename(tmp, configPath);
  return 'updated';
}

async function rotate(dir, pattern, keep) {
  const names = (await fs.readdir(dir)).filter((n) => pattern.test(n)).sort().reverse();
  for (const n of names.slice(keep)) await fs.rm(path.join(dir, n), { recursive: true, force: true });
}

// ── LevelDB snapshot (the backup that precedes every open-for-write) ────────
async function snapshotLevelDb(src, dest) {
  await fs.mkdir(dest, { recursive: true });
  for (const n of await fs.readdir(src)) {
    if (n === 'LOCK') continue;
    await fs.copyFile(path.join(src, n), path.join(dest, n));
  }
}

// ── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  const args = parseArgs(process.argv.slice(2));
  const result = { status: 'unchanged', configState: 'skipped', warnings: [], changes: null, scopesRewritten: [] };
  await fs.mkdir(args.state, { recursive: true });
  const basePath = path.join(args.state, 'groups-base.json');
  let base = null;
  try { base = JSON.parse(await fs.readFile(basePath, 'utf8')); if (!base || !Array.isArray(base.scopes) || !base.entry) base = null; } catch (e) { if (e.code !== 'ENOENT') result.warnings.push(`base unreadable (${e.message}); merging without deletions`); }

  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, '').replace('T', '-');
  const snapshot = path.join(args.state, `leveldb-backup-${stamp}-${process.pid}.tmp`);
  await snapshotLevelDb(args.leveldb, snapshot);
  let snapshotKept = false;

  const db = new ClassicLevel(args.leveldb, { keyEncoding: 'buffer', valueEncoding: 'buffer', createIfMissing: false });
  try {
    try {
      await db.open();
    } catch (e) {
      const cause = e.cause || e;
      if (cause.code === 'LEVEL_LOCKED' || /LockFile|lock/i.test(cause.message || '')) {
        result.status = 'deferred';
        result.reason = 'the app holds the Local Storage lock (it is running)';
        return result;
      }
      throw e;
    }
    const origin = await readOrigin(db, ORIGIN);
    const scopesRec = origin.entries.get(SCOPES_KEY);
    const storeRec = origin.entries.get(STORE_KEY);
    if (!scopesRec && !storeRec) { result.status = 'unchanged'; result.reason = 'no group keys in Local Storage yet'; return result; }
    let scopesWrapper = null; let store = null;
    if (scopesRec) { try { scopesWrapper = JSON.parse(decodeString(scopesRec.value)); } catch { result.warnings.push(`${SCOPES_KEY} is not JSON; ignored`); } }
    if (storeRec) { try { store = JSON.parse(decodeString(storeRec.value)); } catch { result.warnings.push(`${STORE_KEY} is not JSON; ignored`); } }
    const fromLss = scopesWrapper && scopesWrapper.value && typeof scopesWrapper.value === 'object' ? scopesWrapper.value : null;
    const fromStore = store && store.state && store.state.customGroupsByScope && typeof store.state.customGroupsByScope === 'object' ? store.state.customGroupsByScope : null;
    if (!fromLss && !fromStore) { result.status = 'unchanged'; result.reason = 'group keys present but hold no scopes'; return result; }

    // The zustand store is what the sidebar hydrates from; the LSS wrapper is the
    // app's own mirror of it. They agree in every observed state; a disagreement
    // is reported and the store wins.
    const present = {};
    for (const s of args.scopes) {
      const a = fromStore ? fromStore[s] : undefined;
      const b = fromLss ? fromLss[s] : undefined;
      if (a !== undefined && b !== undefined && !deepEqual(a, b)) result.warnings.push(`scope ${s}: store and LSS mirror disagree; store wins`);
      const chosen = a !== undefined ? a : b;
      if (chosen !== undefined) present[s] = chosen;
    }
    const prefer = [];
    if (store && store.state && typeof store.state.lastSidebarScopeKey === 'string') prefer.push(store.state.lastSidebarScopeKey);
    const { entry, changes } = mergeScopes(args.scopes, present, base, prefer);
    result.changes = changes;
    const rewritten = args.scopes.filter((s) => !deepEqual(present[s], entry));
    result.scopesRewritten = rewritten;
    const baseMatches = base && deepEqual(base.entry, entry) && deepEqual([...base.scopes].sort(), [...args.scopes].sort());
    if (rewritten.length === 0 && baseMatches) {
      result.status = 'unchanged';
    } else if (args.dryRun) {
      result.status = 'would-update';
    } else {
      const ops = [];
      let sizeDelta = 0;
      if (fromStore) {
        const next = { ...store, state: { ...store.state, customGroupsByScope: { ...fromStore } } };
        for (const s of args.scopes) next.state.customGroupsByScope[s] = entry;
        const value = encodeString(JSON.stringify(next));
        sizeDelta += value.length - storeRec.value.length;
        ops.push({ type: 'put', key: storeRec.key, value });
      }
      if (fromLss) {
        const next = { ...scopesWrapper, value: { ...fromLss }, timestamp: Date.now() };
        for (const s of args.scopes) next.value[s] = entry;
        const value = encodeString(JSON.stringify(next));
        sizeDelta += value.length - scopesRec.value.length;
        ops.push({ type: 'put', key: scopesRec.key, value });
      } else if (fromStore) {
        const wrapper = { value: {}, tabId: '', timestamp: Date.now() };
        for (const s of args.scopes) wrapper.value[s] = entry;
        const key = Buffer.concat([origin.prefix, encodeString(SCOPES_KEY)]);
        const value = encodeString(JSON.stringify(wrapper));
        sizeDelta += (key.length - origin.prefix.length) + value.length;
        ops.push({ type: 'put', key, value });
      }
      const meta = origin.meta ?? { lastModifiedUs: 0n, sizeBytes: BigInt(origin.sizeBytes) };
      meta.sizeBytes = BigInt(origin.sizeBytes + sizeDelta);
      meta.lastModifiedUs = BigInt(Date.now()) * 1000n + WINDOWS_EPOCH_OFFSET_US;
      ops.push({ type: 'put', key: origin.metaKey, value: encodeMeta(meta) });
      if (rewritten.length > 0) {
        await db.batch(ops);
        result.status = 'updated';
        snapshotKept = true;
      } else {
        result.status = 'unchanged';
      }
      const baseOut = { version: 1, scopes: [...args.scopes], entry, writtenAt: new Date().toISOString() };
      const tmp = `${basePath}.cs-tmp-${process.pid}`;
      await fs.writeFile(tmp, JSON.stringify(baseOut, null, 2));
      await fs.rename(tmp, basePath);
    }
    await db.close();
    if (args.config) {
      // Scopes this sync does not manage ride along untouched from the store.
      const mirror = { ...(fromStore ?? fromLss) };
      for (const s of args.scopes) mirror[s] = entry;
      result.configState = await spliceConfig(args.config, args.state, mirror, args.dryRun, result.warnings);
    }
    return result;
  } finally {
    if (db.status === 'open') await db.close();
    if (snapshotKept) {
      await fs.rename(snapshot, snapshot.replace(/-\d+\.tmp$/, ''));
      await rotate(args.state, /^leveldb-backup-\d{8}-\d{6}$/, LEVELDB_BACKUPS_KEPT);
      result.backupDir = snapshot.replace(/-\d+\.tmp$/, '');
    } else {
      await fs.rm(snapshot, { recursive: true, force: true });
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().then(
    (r) => { process.stdout.write(JSON.stringify(r) + '\n'); process.exit(r.status === 'deferred' ? 3 : 0); },
    (e) => { process.stdout.write(JSON.stringify({ status: 'error', reason: e.message }) + '\n'); process.exit(1); },
  );
}
