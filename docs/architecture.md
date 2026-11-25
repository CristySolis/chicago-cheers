# How Chicago Cheers Works

Friends and family each claim a mile (or half-mile) on the marathon course and record a short audio cheer (up to 25 seconds). On race day, the runner's iPhone plays each recording automatically when she reaches that mile, turning her music down briefly while it plays.

Every design choice comes from two real-world constraints:

1. **Race day has no do-overs.** Cell networks are jammed around the start and downtown, and the phone has to run in an armband for 4.5+ hours on one battery. So the app cannot depend on internet access during the race.
2. **Supporters shouldn't spoil surprises.** People recording cheers shouldn't be able to see who else recorded or listen to anyone else's messages.

---

## High-Level Architecture

```text
Supporter's phone            Backend & Storage               Runner's iPhone
─────────────────            ─────────────────               ───────────────
 sender.html ─────────────▶  FastAPI (Vercel)  ◀───────────  CheerRelay (SwiftUI)
 (pick spot, name,            ├─ Postgres (Supabase):         ├─ Before race: Sync
  record, send)               │   events, seats, cheers       │   (downloads WAVs +
      │                       └─ Object Storage ────────────▶ │    writes manifest)
      └── WAV uploads ───────────▶ (presigned URL)            └─ Race day: offline
          straight to storage                                    GPS -> duck music -> play
```

| Part | Location | What it does |
|---|---|---|
| **Sender web page** | `backend/cheers/web/sender.html` | Single static page served by the API. Bilingual (`EN`/`ES`); records audio directly in the browser. |
| **Backend API** | `backend/cheers/` | FastAPI app on Vercel. Owns all validation, spot allocation, and auth rules. |
| **Database** | `supabase/migrations/` | Plain Postgres tables and one unique constraint—no stored procedures or business logic. |
| **iOS race app** | `ios-app/CheerRelay/` | SwiftUI app. Downloads cheers ahead of time and runs 100% offline on race day. |

### Why audio uploads bypass the API

Serverless functions (like Vercel) have strict request-size limits and short timeouts. Instead of sending a 25-second WAV file through our Python API, the API asks storage for a **single-use upload URL** and hands it to the browser. The browser `PUT`s the audio file straight into storage. That keeps large audio payloads off the API server completely.

---

## Keeping the Backend Clean (`ports.py` and `adapters/`)

The core business logic (`models.py`, `ports.py`, `allocation.py`, `service.py`) is written so it has no idea Supabase or Vercel exist:

- **[`ports.py`](../backend/cheers/ports.py)** defines abstract base classes (`ABC`) for the external services the app needs:
  - `RecordingStore` (create upload/download links, check if a file exists)
  - `IdentityVerifier` (turn a runner's auth token into a user ID)
  - `RunnerSignIn` (sign in and refresh sessions)
- **[`adapters/supabase.py`](../backend/cheers/adapters/supabase.py)** implements those ABCs using Supabase's HTTP APIs.
- **[`config.py`](../backend/cheers/config.py)** wires the real adapters together on startup, and **[`main.py`](../backend/cheers/main.py)** handles HTTP routes.

This boundary isn't just a convention—`import-linter` checks it automatically on every commit and fails CI if core modules import FastAPI, HTTP clients, or Supabase adapters:

```text
Core rules don't depend on providers, wiring or HTTP ... KEPT
Seat ranking stays pure ............................... KEPT
```

Because the database layer ([`repository.py`](../backend/cheers/repository.py)) uses standard SQL via `psycopg` rather than a Supabase-specific SDK, switching hosting (for example, to Google Cloud Run + Cloud SQL + Cloud Storage + Firebase Auth) would only mean writing new adapter classes in `adapters/` and changing the connection string.

---

## How Mile Spots Are Claimed

Each spot on the course has **2 seats** (Seat 1 and Seat 2). That automatically caps an event at `2 × number of spots` cheers without needing a separate counter to keep in sync.

When a supporter picks a spot (say, Mile 10), [`allocation.py`](../backend/cheers/allocation.py) sorts every open seat in priority order:

1. **Seat 1 before Seat 2:** Nobody doubles up on a mile while any other mile is still empty.
2. **At or after the requested mile before earlier ones:** If Mile 10 is full, the cheer slides forward to Mile 11 instead of backward to Mile 9.
3. **Closest first.**

### Handling simultaneous claims without locks

If two people tap Mile 10 at the exact same moment, we don't use a distributed lock or queue. Instead, the Postgres table has a unique constraint (`one_person_per_seat`) on `(event_id, slot, seat)`.

Both requests try to `INSERT`:
- The first one wins.
- The second one hits the unique constraint, catches `SeatTaken` in the service, and retries the next-best seat from the list.

### Two-step upload flow (so broken uploads don't break race day)

```text
1. POST /api/events/{share_code}/claims   -> reserves seat, returns 1-time upload URL
2. Browser PUTs WAV straight to storage
3. POST /api/claims/{cheer_id}/complete   -> API checks the file actually exists in storage
                                             before marking the cheer ready for the phone
```

A newly claimed row has no `audio_path` yet, so it's treated as a temporary **reservation**, not a finished cheer, and never shows up on the runner's phone:

- If someone closes their tab before finishing the upload, the reservation expires after **15 minutes**.
- Expired reservations are deleted automatically at the start of the next claim—no background cron job needed.
- `complete` checks storage directly before finalizing the row, so a silent upload failure never leaves the phone trying to download a missing file.

---

## Privacy Between Supporters

- **Counts only on public pages:** The sender page endpoint returns how many cheers each mile has, never supporter names or audio URLs.
- **Opaque share links:** Supporters only ever see the random `share_code` in the URL.
- **No event enumeration:** Asking for another runner's event returns the same "not found" error as a nonexistent event, so nobody can probe which IDs exist.
- **Scoped storage URLs:** Senders get a single-use upload link for one specific path (with overwrite disabled); only the signed-in runner gets temporary download links for her own event.
- **Supabase auto-API locked down:** Supabase automatically exposes tables via a built-in REST API. Enabling Postgres Row-Level Security (RLS) with **zero policies** blocks that API completely, so every read and write must go through our FastAPI backend.

---

## The iOS App (`CheerRelay`)

### 1. Pre-race sync vs. race-day playback

Syncing happens **before** the race, never during it. When the runner taps **Sync**, the app downloads each WAV file and saves a local manifest. During the race, the UI reads only through [`CheerSource`](../ios-app/CheerRelay/CheerSource.swift), a Swift protocol whose contract is *"all audio is already on disk."*

Three small details prevent data loss:

- **Stored in `Application Support`, not `Caches`:** iOS automatically clears `Caches` when phone storage runs low—which could wipe recordings overnight before the race.
- **Manifest-driven playback:** Old audio files aren't deleted aggressively during sync, and the manifest only points to valid downloaded files, so a partial or failed sync can't destroy cheers already on the phone.
- **Incremental downloads:** Completed cheers are immutable on the server, so re-syncing after one new recording arrives only downloads that one new file.

### 2. Measuring distance accurately in a downtown marathon

A naive GPS tracker adds up the straight-line distances between consecutive `(lat, lon)` coordinates. The problem is that every GPS fix is off by a few meters in a random direction, creating a **zigzag path** that is longer than the straight line actually run:

- In field testing, naive position-to-position summing read **~6% long** (already 200 m off by mile 2, or ~1.6 miles off by the finish).
- Around tall downtown skyscrapers (like Chicago's Loop), simulated GPS bounce pushed that error past **20%**.

Instead, [`DistanceMeter`](../ios-app/CheerRelay/DistanceMeter.swift) uses the GPS chip's **Doppler speed** (which measures velocity directly from satellite frequency shift and doesn't zigzag like coordinates do). On each update, it multiplies average speed by elapsed time (`(prev.speed + fix.speed) / 2 * elapsed`), falling back to coordinate distance only when speed isn't reported (ignoring steps ≤ 1 m in that fallback as standing jitter). In the same urban simulation, that stayed within **0.2%**.

Before counting any GPS update, `DistanceMeter` also filters out bad fixes:

| Filter | Why |
|---|---|
| `horizontalAccuracy >= 25 m` (or `<= 0`) | Fix is too imprecise to trust |
| Timestamp older than `5 s` on arrival | iOS sometimes delivers a cached position from earlier |
| Implied speed `>= 8 m/s` | Faster than marathon sprint speed—indicates a GPS jump |

`DistanceMeter` is a pure Swift struct with no location manager, storage, or clock, so unit tests feed it synthetic GPS points directly. [`RaceTracker`](../ios-app/CheerRelay/RaceTracker.swift) owns `CLLocationManager` and persistence:

- **10-meter accuracy** instead of "best": cheers don't need centimeter precision, and 10 m uses noticeably less battery over 4.5+ hours.
- **`pausesLocationUpdatesAutomatically = false`**: prevents iOS from pausing GPS if the runner slows down at a water station or crowded turn.
- **Saved on every update**: if the app crashes or the phone restarts at mile 14, it resumes from mile 14 instead of replaying miles 1–13.

### 3. Course spacing & audio ducking

- **39 spots total:** One per mile for Miles 1–13, then one every half-mile from Mile 13.5 to 26. That puts **26 of 39 cheers in the second half** (more support when fatigue sets in) while still lining up with the mile markers painted on the course.
- **Queued & ducked audio:** If a spot has two cheers, they play one after another instead of overlapping, and the audio session temporarily lowers ("ducks") whatever music or podcast is playing rather than stopping it.

### 4. Race-morning readiness check

[`Readiness`](../ios-app/CheerRelay/Readiness.swift) inspects a snapshot of the phone—location permission, sign-in state, synced cheers, missing audio files, sync age, battery level, headphone connection, and volume—and groups issues into blocking **problems** vs. **warnings** with one-tap fixes. Because it's pure functions over a plain struct, all rules are unit-tested without a physical iPhone.

It also includes a **Play test sound** button that plays three beeps through the exact same audio-ducking queue used on race day, so the runner can confirm music dips properly in her headphones before starting.

---

## Testing Strategy

| Suite | Requires | What it tests |
|---|---|---|
| `backend/tests/test_allocation.py` | Nothing | Seat-ranking rules (Seat 1 vs. Seat 2, forward slide, nearest) |
| `backend/tests/api/` | Local Supabase (Docker) | End-to-end HTTP endpoints, auth, and concurrent claim races |
| `ios-app/CheerRelayTests/` | Xcode 26+ | Course mile layout, `DistanceMeter` GPS filters & math, `RaceLog`, `Readiness` rules |

We put pure business rules (seat ranking, GPS math, readiness checks) into standalone, dependency-free modules so they're fast and easy to test in isolation, while keeping external adapters thin enough to verify end-to-end against local Supabase.

---

## What Would Change If Hosting Changed

| Today | Alternative | Effort to swap |
|---|---|---|
| Vercel serverless function | Google Cloud Run container | None—standard ASGI (`FastAPI`) app |
| Supabase Postgres | Cloud SQL (Postgres) | Change `DATABASE_URL` |
| Supabase Storage | Google Cloud Storage | Implement `RecordingStore` ABC |
| Supabase Auth | Firebase Auth | Implement `IdentityVerifier` & `RunnerSignIn` ABCs |
| Supabase RLS lock | Not needed on Cloud SQL | No auto-REST API to block |
