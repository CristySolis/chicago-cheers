#!/usr/bin/env sh
# Runs the tests under tests/api, which exercise the API over HTTP against a
# local Supabase. Needs `npx supabase start` to have been run from the repo
# root first.

set -e
cd "$(dirname "$0")"

# Local-only keys and URLs, identical on every machine running Supabase locally.
eval "$(cd .. && npx --yes supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY|DB_URL)=')"
export API_URL ANON_KEY SERVICE_ROLE_KEY DB_URL

# Clear addopts, which excludes these tests from the default run.
poetry run pytest -o addopts="" tests/api "$@"
