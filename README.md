# Chicago Cheers

Friends and family each claim a mile of the Chicago Marathon (11 October 2026)
and record a cheer of up to 25 seconds. On race day, Cristy's iPhone plays
each cheer when Cristy reaches its mile, turning the music down while it
plays. Everything is downloaded to the phone beforehand, so the race itself
needs no signal.

```
 supporter's phone              the internet                 Cristy's iPhone
┌──────────────────┐   ┌─────────────────────────────┐   ┌──────────────────────┐
│ sender page       │──▶│ API (Python, on Vercel)      │◀──│ race app: Sync       │
│ pick mile, name,  │   │   │                          │   │ (before the race)    │
│ record, send      │   │   ├─ database: who, which mile│   │                      │
└────────┬─────────┘   │   └─ storage: the recordings  │──▶│ race day: GPS → mile │
         └────────────▶│      (uploaded straight here) │   │ → play the cheer     │
                        └─────────────────────────────┘   └──────────────────────┘
```

The database and storage are [Supabase](https://supabase.com); the API and the
sender page are hosted on [Vercel](https://vercel.com) at
`https://chicago-cheers.vercel.app`. A fuller explanation with diagrams is in the
[architecture doc](https://claude.ai/code/artifact/bcfec7d7-4a3e-4ef8-9b1b-7a55dac6068d).

## What's where

| Folder | What it is |
|---|---|
| `backend/` | The API and the sender page (`cheers/web/sender.html`). Python, Poetry. |
| `supabase/` | Database tables (`migrations/`) and storage settings (`config.toml`). Tables and rules only — all logic lives in `backend/`. |
| `ios-app/` | The race app, CheerRelay (SwiftUI). |
| `watch-app/` | Leftover from the first design (text cheers on a Garmin watch). Not used: the Forerunner 935 can't do it. |

## Running the race

### Collecting cheers

Send supporters the link `https://chicago-cheers.vercel.app/cheer/<share_code>`.
The `share_code` is on the race's row in Supabase (**Table Editor → events**).

The page follows each phone's language (English or Spanish, with a switch). A
supporter picks a mile, types a name and records. Rules the page and API
enforce:

- One person per mile until every mile has a cheer; then a second person can
  join any mile. Never more than two.
- If someone takes a mile a moment before you, your cheer slides to the next
  free one and the page says where it went.
- Supporters never see each other's names or recordings.

### Looking after cheers (Supabase dashboard)

Each cheer is a **row** in the `cheers` table plus an **audio file** in the
`cheers` storage bucket. The row is what counts: it holds the mile and is what
the phone downloads the list from.

- **Delete a cheer:** delete its row (**Table Editor → cheers**), then its file
  (**Storage → cheers →** the race's folder). Deleting only the file would leave
  the mile taken and the phone trying to download something that's gone.
- **Stop taking cheers:** set `submissions_open` to `false` on the race's row
  in **events**. The page then says cheers are closed.
- **The name on the page:** `runner_name` on the race's row.
- Never delete the race's row in **events**: that breaks the link and sync.

### On the phone

1. **Sign in** once with the runner account (created in Supabase under
   **Authentication**).
2. Tap **Sync** whenever new cheers arrive. It downloads them and shows the next
   one coming up. A final sync the night before the race is the one that
   matters.
3. On race day, open the app, tap **Start** at the start line, lock the phone. Sync
   is switched off while a run is going.

A cheer deleted in Supabase disappears from the phone at the next sync.

## Building the phone app

Needs a Mac with Xcode and CocoaPods, and the iPhone connected by cable.

1. Open **`ios-app/CheerRelay.xcworkspace`** (the workspace, not the
   `.xcodeproj`).
2. Pick which server the app talks to. The build configuration decides it:
   - **Debug** → the API running on this Mac (`http://127.0.0.1:8000`), for
     development.
   - **Release** → the live API. **Use this for the real phone.**

   In Xcode: **Product → Scheme → Edit Scheme… → Run → Build Configuration**.
3. Choose the iPhone at the top of the window and press **Run** (▶).

With a free Apple account the installed app **stops opening after 7 days**.
Rebuild it on **9 or 10 October** so it's valid through race day. Synced
cheers survive a rebuild.

## Developing the backend

Needs Python 3.12, Poetry 1.8, Node (for `npx supabase`) and Docker Desktop.

```bash
cd backend && poetry install
```

Start a local copy of Supabase (database, storage, sign-in) from the repo root:

```bash
npx supabase start
```

Then, from `backend/`:

| Command | Does |
|---|---|
| `./serve-local.sh` | Runs the API and page on http://127.0.0.1:8000 against local Supabase. |
| `./lint.sh` | Formatting, import rules, type checks and the fast tests. Run before every commit. |
| `./integration-tests.sh` | The API tests, against local Supabase. |
| `./export-requirements.sh` | Regenerates `requirements.txt` after any dependency change (Vercel reads that file, not Poetry's). |

To try the sender page locally, add a race in local Supabase's Studio
(http://127.0.0.1:54323) and open `http://127.0.0.1:8000/cheer/<its share_code>`.

## Deploying

Vercel deploys `main` automatically: its project uses `backend/` as the root
directory, with these environment variables set in Vercel's settings:
`DATABASE_URL` (Supabase's transaction pooler), `SUPABASE_URL`,
`SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_KEY`. Secrets live only there, never
in the repo.

**Database changes go out before the code that uses them.** A new migration in
`supabase/migrations/` is applied to the live database with

```bash
npx supabase db push --linked
```

and only then is the pull request merged. Keep migrations additive (new
columns nullable), so the code already live keeps working in between.

## Before race day

- [ ] Delete the test cheers so every mile is free for real people.
- [ ] Share the link with supporters; close submissions a day or two before.
- [ ] Rebuild the app on 9–10 October (Release), sign in, sync.
- [ ] A long run with the app, phone locked, to check battery and GPS timing.
- [ ] Race morning: final sync on Wi-Fi, headphones connected, start at the line.
