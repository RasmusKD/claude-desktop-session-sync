// Test-only helper: builds and inspects Chromium-style Local Storage LevelDBs so
// the Pester suite can exercise the group sync against fixtures. Resolves
// classic-level from ../group-sync/node_modules, the same copy the engine uses.
//
//   node leveldb-fixture.mjs create <dir> <entries.json>   entries: {"<name>": <json value>}
//   node leveldb-fixture.mjs read <dir> <name>            prints the decoded value
//   node leveldb-fixture.mjs meta <dir>                   prints {sizeBytes, computed}
//   node leveldb-fixture.mjs hold <dir> <ms>              opens the DB and keeps the lock
import { createRequire } from 'node:module';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(here, '..', 'group-sync', 'package.json'));
const { ClassicLevel } = require('classic-level');

const ORIGIN = 'https://claude.ai';
const prefix = Buffer.from(`_${ORIGIN}\0`, 'latin1');

function encodeString(s) {
  let latin1 = true;
  for (let i = 0; i < s.length; i++) if (s.charCodeAt(i) > 0xff) { latin1 = false; break; }
  return latin1
    ? Buffer.concat([Buffer.from([0x01]), Buffer.from(s, 'latin1')])
    : Buffer.concat([Buffer.from([0x00]), Buffer.from(s, 'utf16le')]);
}
function decodeString(b) {
  if (b[0] === 0x00) return b.subarray(1).toString('utf16le');
  return b.subarray(1).toString('latin1');
}
function encodeVarint(n) {
  const bytes = []; let v = BigInt(n);
  do { let b = Number(v & 0x7fn); v >>= 7n; if (v > 0n) b |= 0x80; bytes.push(b); } while (v > 0n);
  return Buffer.from(bytes);
}
function decodeVarint(buf, pos) {
  let result = 0n; let shift = 0n;
  for (;;) { const b = buf[pos++]; result |= BigInt(b & 0x7f) << shift; if ((b & 0x80) === 0) return [result, pos]; shift += 7n; }
}

const [cmd, dir, arg] = process.argv.slice(2);
const open = () => new ClassicLevel(dir, { keyEncoding: 'buffer', valueEncoding: 'buffer' });

if (cmd === 'create') {
  const entries = JSON.parse(await fs.readFile(arg, 'utf8'));
  const db = open();
  await db.open();
  const ops = [{ type: 'put', key: Buffer.from('VERSION', 'latin1'), value: Buffer.from('1', 'latin1') }];
  let size = 0;
  for (const [name, value] of Object.entries(entries)) {
    const key = Buffer.concat([prefix, encodeString(name)]);
    const val = encodeString(typeof value === 'string' ? value : JSON.stringify(value));
    size += (key.length - prefix.length) + val.length;
    ops.push({ type: 'put', key, value: val });
  }
  const lastModified = BigInt(Date.now()) * 1000n + 11644473600000000n;
  ops.push({ type: 'put', key: Buffer.from(`META:${ORIGIN}`, 'latin1'), value: Buffer.concat([Buffer.from([0x08]), encodeVarint(lastModified), Buffer.from([0x10]), encodeVarint(size)]) });
  await db.batch(ops);
  await db.close();
} else if (cmd === 'read') {
  const db = open();
  await db.open();
  try {
    const v = await db.get(Buffer.concat([prefix, encodeString(arg)]));
    // abstract-level 2 resolves undefined for a missing key; older majors threw.
    process.stdout.write(v === undefined ? '' : decodeString(v));
  } catch (e) {
    if (e.code !== 'LEVEL_NOT_FOUND') throw e;
    process.stdout.write('');
  }
  await db.close();
} else if (cmd === 'meta') {
  const db = open();
  await db.open();
  let computed = 0;
  for await (const [k, v] of db.iterator({ gte: prefix, lt: Buffer.concat([prefix, Buffer.from([0xff])]) })) computed += (k.length - prefix.length) + v.length;
  const meta = await db.get(Buffer.from(`META:${ORIGIN}`, 'latin1'));
  let pos = 0; let sizeBytes = -1n;
  while (pos < meta.length) { const tag = meta[pos++]; const [val, next] = decodeVarint(meta, pos); pos = next; if (tag === 0x10) sizeBytes = val; }
  process.stdout.write(JSON.stringify({ sizeBytes: Number(sizeBytes), computed }));
  await db.close();
} else if (cmd === 'hold') {
  const db = open();
  await db.open();
  process.stdout.write('held\n');
  await new Promise((r) => setTimeout(r, Number(arg)));
  await db.close();
} else {
  throw new Error(`unknown command ${cmd}`);
}
