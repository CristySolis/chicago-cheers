# How Chicago Cheers works

Friends and family each claim a spot on the course and record a short cheer.
On race day the runner's phone plays each one when she reaches that spot,
turning the music down while it plays.

Two things shape every decision below:

1. **Race day has no second try.** The phone must work on a saturated network
   in the Loop, in an armband, for four and a half hours, on one battery.
2. **Supporters are strangers to each other.** Nobody should be able to see who
   else recorded, or hear anything they sent.

## The three parts

```
Supporter's phone            The internet                    The runner's iPhone

 sender page ────────────▶  API (Python, on Vercel)  ◀────────  Sync
 (pick spot, name,           ├─ Postgres: who, which spot       (before the race)
  record, send)              └─ storage: the recordings ──────▶
      │                              ▲                          race day: GPS → spot
      └── recording uploads ─────────┘                          → play the cheer
          straight to storage
```

| Part | Where | What it is |
|---|---|---|
| Sender page | `backend/cheers/web/sender.html` | One static file, served by the API. Bilingual (English/Spanish), records in the browser. |
| API | `backend/cheers/` | FastAPI on Vercel. Holds every rule. |
| Database | `supabase/migrations/` | Plain Postgres. Structure and one constraint, no logic. |
| Race app | `ios-app/CheerRelay/` | SwiftUI. Syncs before the race, runs offline during it. |

Recordings never pass through the API. The API hands out a link that accepts
one upload to one path, and the browser PUTs the file straight to storage —
so a 25-second WAV never has to fit inside a serverless function's limits.

## The rule the backend is built around

The core — `models`, `ports`, `allocation`, `service` — doesn't know that
Supabase or Vercel exist. Everything provider-shaped sits behind a Protocol in
[`ports.py`](../backend/cheers/ports.py): somewhere to put recordings, something
that turns a token into a runner id, something that signs her in.
[`config.py`](../backend/cheers/config.py) is the only file that names Supabase,
and [`main.py`](../backend/cheers/main.py) is the only one that knows about HTTP.

This isn't a claim in a comment — `import-linter` enforces it on every commit,
and CI fails if it's broken:

```
Core rules don't depend on providers, wiring or HTTP ... KEPT
Seat ranking stays pure ............................... KEPT
```

The database needs no such seam. It's plain Postgres, which Cloud SQL also is,
so [`repository.py`](../backend/cheers/repository.py) writes SQL directly rather
than going through Supabase's client. Moving the whole thing to Google Cloud
means three new adapter classes and a different connection string.

## Claiming a spot

Every spot on the course has **two seats**: the first person, and whoever
doubles up once every spot is taken. Two seats per spot also caps the event at
twice its spots, with no separate limit to keep in step.

When a supporter asks for a spot, [`allocation.py`](../backend/cheers/allocation.py)
ranks every free seat — 35 lines, no database, no clock:

1. First seats before second, so nobody doubles up while a spot is still free.
2. Spots at or after the one asked for before earlier ones, so a taken spot
   slides to the *next* one rather than backwards.
3. Nearest first.

Then the service walks that ranking and tries to take each seat in turn.

**Two people pressing the button at the same moment is handled by the database,
not by a lock.** The `one_person_per_seat` unique constraint accepts one insert
and refuses the other; the loser catches `SeatTaken` and moves to the next best
seat. That's why the ranking is allowed to come from a snapshot that's already
slightly stale — being wrong about what's free costs one retry, not a bad
answer.

### A claim is not yet a cheer

```
POST /api/events/{share_code}/claims   seat taken, upload link handed back
        │
        ▼  browser PUTs the WAV straight to storage
POST /api/claims/{cheer_id}/complete   API checks the file is really there
        │
        ▼
   visible to the runner's phone
```

A row with no `audio_path` is a reservation, not a cheer, and never reaches the
phone. Reservations hold their seat for 15 minutes — long enough for a slow
phone connection, short enough that an abandoned browser tab doesn't keep a
spot from someone else. Lapsed ones are swept on the next claim, so there's no
scheduled job to go wrong.

`complete` verifies the file exists in storage before marking the row finished.
A claim whose upload silently failed stays invisible rather than becoming a
cheer the phone tries to download and can't.

## Keeping supporters apart

- The public event endpoint returns **counts per spot, never names**. There is
  no endpoint that lists who recorded, and none that returns another
  supporter's audio.
- A share code is the only handle a supporter has. It identifies the event and
  nothing else.
- Asking for someone else's event as the runner returns the same answer as an
  event that doesn't exist, so the API can't be used to discover which events
  are real.
- Nobody gets standing access to storage. Senders get a link that accepts one
  file at one path and refuses to overwrite; the runner gets time-limited
  download links for her own recordings.
- Supabase publishes every table through an automatic REST API.
  **Row-level security is enabled with no policies at all**, which closes that
  door completely — the Python API is the only way in, and its rules can't be
  walked around. On Cloud SQL there is no such API and the line is simply inert.

## The phone

### Sync is a step, not a background process

Sync runs **before** the race, never during it. It signs in, fetches the
runner's cheers, downloads each WAV, and writes a manifest. After that the race
reads only what's on disk.

Three details that matter more than they look:

- **Only the manifest decides what plays.** Files it no longer names are left
  in place rather than deleted, so a bad answer from the server can never
  destroy recordings the phone already holds.
- **Files live in Application Support, not Caches.** iOS empties Caches when
  storage runs low, and the night before a marathon is exactly when that must
  not happen.
- **A finished recording can never change on the server**, so a file already on
  the phone is kept rather than fetched again. Re-syncing after one new cheer
  downloads one file.

The race screen reads through [`CheerSource`](../ios-app/CheerRelay/CheerSource.swift),
a protocol whose contract is *the audio is already on this device*. Fetching the
catalogue and making it available offline are deliberately separate steps, which
is what keeps the network out of race day entirely.

### Distance, and the mistake worth writing down

The obvious way to measure distance is to add up the gaps between GPS fixes.
It reads about **6% long** — 200 m by mile 2, which would be 1.6 miles by the
finish — and simulating noisier reception, like the Loop's towers, pushes that
past **20%**. Every fix is a few metres off in a direction that wanders, so the
traced path zigzags, and a zigzag is longer than the line actually run.

The receiver's Doppler speed doesn't wobble that way — within 0.2% in the same
simulation. So [`DistanceMeter`](../ios-app/CheerRelay/DistanceMeter.swift)
**integrates speed over time**, falling back to position only when speed isn't
reported. It also drops fixes that would poison the total:

| Gate | Why |
|---|---|
| accuracy worse than 25 m | too vague to count |
| fix older than 5 s on arrival | iOS sometimes delivers a cached position first, which would count distance from the wrong place |
| implied pace over 8 m/s | a bad fix, far faster than any marathon pace |
| under 1 m of movement | jitter while standing still |

`DistanceMeter` is a pure struct with no location manager, no storage and no
clock of its own, so the tests feed it invented fixes and assert on the
arithmetic. [`RaceTracker`](../ios-app/CheerRelay/RaceTracker.swift) owns the
GPS and the saving; the maths is separate from both.

Precision deliberately isn't the goal: a cheer placed at mile 18 reads the same
arriving 100 m early or late. So the location manager asks for ten-metre
accuracy rather than best — materially kinder to the battery over four and a
half hours. Two settings exist purely because the race is long:
`pausesLocationUpdatesAutomatically = false`, because iOS otherwise decides the
runner has stopped and silently ends updates; and progress written to disk on
every single update, because an app restart at mile 14 must not replay miles
1 through 13.

### Where the cheers go

One per mile for the first half, where the runner is fresh and the crowds are
already thick; one per half mile for the second, where they're needed most.
That puts 26 of the 39 spots in the back half — more than switching to
kilometres would give (21) — while still matching the mile markers painted on
the course, so a cheer expected at mile 20 lines up with a sign the runner can
actually see.

Cheers queue rather than overlap, since a spot can hold two once everything is
claimed, and they duck whatever else is playing rather than stopping it.

### The race-morning checklist

[`Readiness`](../ios-app/CheerRelay/Readiness.swift) reads the phone at one
moment — location permission, sign-in, cheers on disk, cheers missing audio,
time since last sync, battery, output route, volume — and turns it into four
items with a one-tap fix each. A *problem* means cheers won't play, or not in
the right place; a *warning* means they'll play but something is worth a look:
quiet volume, playing through the speaker, a battery that may not last. The
rules are plain functions over a plain snapshot struct, so they're tested
without a phone.

There's also a sound check: three generated beeps played through exactly the
same queue and ducking as a real cheer, so headphones and volume can be proven
at the start line rather than hoped about.

## Testing

| Suite | Needs | Covers |
|---|---|---|
| `backend/tests/test_allocation.py` | nothing | seat ranking |
| `backend/tests/api/` | local Supabase (Docker) | the API end to end, including concurrent claims |
| `ios-app/CheerRelayTests/` | Xcode 26+ | course spots, distance maths, race log, readiness rules |

The split is deliberate: the logic that decides *where a cheer lands* and *when
it plays* is pure and tested in isolation, because that's the part with real
rules in it. The provider-shaped code is thin enough to read.

CI runs the backend checks on every push and pull request. The API tests and the
iOS tests run locally — the first needs Docker, the second needs Xcode.

## What would change if the hosting changed

| Today | Instead | Work |
|---|---|---|
| Vercel function | Cloud Run container | none — it's a standard ASGI app |
| Supabase Postgres | Cloud SQL | connection string |
| Supabase Storage | Cloud Storage | one adapter class |
| Supabase Auth | Firebase Auth | two adapter classes |
| Supabase's REST API, closed by RLS | doesn't exist | nothing; the line goes inert |

The sender page is served by the API rather than by static hosting, so the page
and the API it calls always share an origin and move hosts together.
