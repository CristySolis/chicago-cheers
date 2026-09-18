#!/usr/bin/env sh
# Runs the API on http://127.0.0.1:8000 against the local Supabase, for trying
# the sender page or the iPhone app in the Simulator. Needs `npx supabase start`
# to have been run from the repo root first.

set -e
cd "$(dirname "$0")"

# Local-only keys and URLs, identical on every machine running Supabase locally.
eval "$(cd .. && npx --yes supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY|DB_URL)=')"

export DATABASE_URL="$DB_URL"
export SUPABASE_URL="$API_URL"
export SUPABASE_SERVICE_KEY="$SERVICE_ROLE_KEY"
export SUPABASE_ANON_KEY="$ANON_KEY"

poetry run uvicorn cheers.main:app --host 127.0.0.1 --port 8000 "$@"
