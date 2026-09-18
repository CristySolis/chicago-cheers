// Behavioural tests for the cheers backend, run against a local stack:
//
//   npx supabase start
//   cd supabase/tests && npm install
//   eval "$(npx supabase status -o env)" && npm test
//
// These exercise the rules that matter on race day through the same public
// API the sender page and the phone use — not the SQL directly.

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import ws from "ws";

const url = process.env.API_URL;
const anonKey = process.env.ANON_KEY ?? process.env.PUBLISHABLE_KEY;
const serviceKey = process.env.SERVICE_ROLE_KEY ?? process.env.SECRET_KEY;
if (!url || !anonKey || !serviceKey) {
  throw new Error('Run with: eval "$(npx supabase status -o env)"');
}

// supabase-js builds a realtime client even when it's unused, and on Node
// below 22 that needs a WebSocket implementation handed to it.
const quiet = {
  auth: { persistSession: false, autoRefreshToken: false },
  realtime: { transport: ws },
};
const admin = createClient(url, serviceKey, quiet);
const anon = () => createClient(url, anonKey, quiet);

// Chicago: one spot per mile to 13, then one per half mile — 39 in all.
const CHICAGO = [
  ...Array.from({ length: 13 }, (_, i) => i + 1),
  ...Array.from({ length: 26 }, (_, i) => 13.5 + i * 0.5),
];

async function runner() {
  const email = `runner-${randomUUID()}@test.local`;
  const password = randomUUID();
  const { data, error } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
  });
  if (error) throw error;
  const client = createClient(url, anonKey, quiet);
  const { error: signInError } = await client.auth.signInWithPassword({ email, password });
  if (signInError) throw signInError;
  return { id: data.user.id, client };
}

async function event(owner, overrides = {}) {
  const { data, error } = await admin
    .from("events")
    .insert({
      owner_id: owner.id,
      name: "Chicago Marathon 2026",
      unit: "mi",
      slots: CHICAGO,
      max_cheers: CHICAGO.length * 2,
      ...overrides,
    })
    .select()
    .single();
  if (error) throw error;
  return data;
}

async function claim(code, preferred, sender = "someone") {
  const { data, error } = await anon().rpc("claim_slot", {
    code, preferred, sender,
  });
  // supabase-js reports errors as plain objects, which assert.rejects can't
  // match a message pattern against.
  if (error) throw new Error(error.message);
  return data[0];
}

// A real, minimal WAV: silence, so the bucket's type check is honest.
function wav() {
  const samples = 800;
  const b = Buffer.alloc(44 + samples * 2);
  b.write("RIFF", 0); b.writeUInt32LE(36 + samples * 2, 4); b.write("WAVE", 8);
  b.write("fmt ", 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20);
  b.writeUInt16LE(1, 22); b.writeUInt32LE(8000, 24); b.writeUInt32LE(16000, 28);
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(samples * 2, 40);
  return b;
}

async function upload(client, path) {
  return client.storage.from("cheers").upload(path, wav(), {
    contentType: "audio/wav", upsert: false,
  });
}

// Claims a spot and completes it with a recording, the way the page will.
async function cheer(ev, preferred, sender) {
  const c = await claim(ev.share_code, preferred, sender);
  const { error } = await upload(anon(), `${ev.id}/${c.cheer_id}.wav`);
  if (error) throw error;
  const { error: attachError } = await anon().rpc("attach_audio", { the_cheer: c.cheer_id });
  if (attachError) throw attachError;
  return c;
}

let her;
let otherRunner;
before(async () => {
  her = await runner();
  otherRunner = await runner();
});

// --- Claiming ---------------------------------------------------------------

test("a free spot goes to whoever asks for it", async () => {
  const ev = await event(her);
  const c = await claim(ev.share_code, 18);
  assert.equal(Number(c.assigned_slot), 18);
});

test("a taken spot slides to the next free one after it", async () => {
  const ev = await event(her);
  await claim(ev.share_code, 18);
  const c = await claim(ev.share_code, 18);
  assert.equal(Number(c.assigned_slot), 18.5);
});

test("with nothing free after it, the nearest free spot before is used", async () => {
  const ev = await event(her);
  await claim(ev.share_code, 26);
  const c = await claim(ev.share_code, 26);
  assert.equal(Number(c.assigned_slot), 25.5);
});

test("nobody doubles up while any spot is still free", async () => {
  const ev = await event(her);
  for (const s of CHICAGO.slice(1)) await claim(ev.share_code, s);
  // Only mile 1 is left; someone asking for mile 20 must get it, not a double.
  const c = await claim(ev.share_code, 20);
  assert.equal(Number(c.assigned_slot), 1);
});

test("once every spot is held, the next cheer doubles up where it asked", async () => {
  const ev = await event(her);
  for (const s of CHICAGO) await claim(ev.share_code, s);
  const c = await claim(ev.share_code, 20);
  assert.equal(Number(c.assigned_slot), 20);
});

test("simultaneous claims on one spot never land on the same place", async () => {
  const ev = await event(her);
  const results = await Promise.all(
    Array.from({ length: 25 }, (_, i) => claim(ev.share_code, 20, `racer ${i}`)),
  );
  const slots = results.map((r) => Number(r.assigned_slot));
  assert.equal(new Set(slots).size, slots.length, `duplicates in ${slots}`);
  assert.ok(slots.includes(20));
});

test("the event refuses cheers past its ceiling", async () => {
  const ev = await event(her, { max_cheers: 2 });
  await claim(ev.share_code, 1);
  await claim(ev.share_code, 2);
  await assert.rejects(claim(ev.share_code, 3), /full/);
});

test("a spot that isn't on the course is refused", async () => {
  const ev = await event(her);
  await assert.rejects(claim(ev.share_code, 7.5), /not a spot/);
});

test("closed events refuse new cheers", async () => {
  const ev = await event(her, { submissions_open: false });
  await assert.rejects(claim(ev.share_code, 5), /closed/);
});

test("an abandoned claim frees its spot after the upload window", async () => {
  const ev = await event(her);
  const abandoned = await claim(ev.share_code, 10);
  await admin
    .from("cheers")
    .update({ created_at: new Date(Date.now() - 20 * 60_000).toISOString() })
    .eq("id", abandoned.cheer_id);
  const c = await claim(ev.share_code, 10);
  assert.equal(Number(c.assigned_slot), 10);
});

// --- Anonymity ---------------------------------------------------------------

test("senders see how full each spot is, but never who is in it", async () => {
  const ev = await event(her);
  await cheer(ev, 18, "Mum");
  await cheer(ev, 20, "Tete");

  const { data: rows } = await anon().from("cheers").select("*");
  assert.deepEqual(rows, [], "anon read the cheers table directly");

  const { data: occupancy } = await anon().rpc("slot_occupancy", { code: ev.share_code });
  const spots = occupancy
    .map((r) => ({ slot: Number(r.slot), cheers: r.cheers }))
    .sort((a, b) => a.slot - b.slot);
  assert.deepEqual(spots, [{ slot: 18, cheers: 1 }, { slot: 20, cheers: 1 }]);
  assert.ok(!/Mum|Tete/.test(JSON.stringify(occupancy)), "a name leaked");
});

test("the public event details leave out the owner", async () => {
  const ev = await event(her);
  const { data } = await anon().rpc("event_for_share_code", { code: ev.share_code });
  assert.equal(data[0].name, "Chicago Marathon 2026");
  assert.ok(!("owner_id" in data[0]));
});

test("a runner sees their own cheers, with names, and nobody else's", async () => {
  const ev = await event(her);
  await cheer(ev, 18, "Mum");

  const { data: hers } = await her.client.from("cheers").select("sender_name").eq("event_id", ev.id);
  assert.deepEqual(hers, [{ sender_name: "Mum" }]);

  const { data: theirs } = await otherRunner.client.from("cheers").select("*").eq("event_id", ev.id);
  assert.deepEqual(theirs, []);
});

// --- Recordings ---------------------------------------------------------------

test("a sender can upload to their own claim and nowhere else", async () => {
  const ev = await event(her);
  const c = await claim(ev.share_code, 12);

  const ok = await upload(anon(), `${ev.id}/${c.cheer_id}.wav`);
  assert.equal(ok.error, null);

  const stray = await upload(anon(), `${ev.id}/${randomUUID()}.wav`);
  assert.ok(stray.error, "uploaded to a path with no claim");
});

test("a finished cheer can't have its recording replaced", async () => {
  const ev = await event(her);
  const c = await cheer(ev, 12, "Mum");
  const again = await upload(anon(), `${ev.id}/${c.cheer_id}.wav`);
  assert.ok(again.error, "overwrote a finished recording");
});

test("a claim can't be marked finished without its recording", async () => {
  const ev = await event(her);
  const c = await claim(ev.share_code, 12);
  const { error } = await anon().rpc("attach_audio", { the_cheer: c.cheer_id });
  assert.match(error?.message ?? "", /not been uploaded/);
});

test("only the event's runner can download its recordings", async () => {
  const ev = await event(her);
  const c = await cheer(ev, 12, "Mum");
  const path = `${ev.id}/${c.cheer_id}.wav`;

  const mine = await her.client.storage.from("cheers").download(path);
  assert.equal(mine.error, null);

  const other = await otherRunner.client.storage.from("cheers").download(path);
  assert.ok(other.error, "another runner downloaded it");

  const stranger = await anon().storage.from("cheers").download(path);
  assert.ok(stranger.error, "an anonymous caller downloaded it");
});

test("only finished cheers count once their claim window has passed", async () => {
  const ev = await event(her);
  const pending = await claim(ev.share_code, 14);
  await admin
    .from("cheers")
    .update({ created_at: new Date(Date.now() - 20 * 60_000).toISOString() })
    .eq("id", pending.cheer_id);
  const { data } = await anon().rpc("slot_occupancy", { code: ev.share_code });
  assert.deepEqual(data, []);
});
