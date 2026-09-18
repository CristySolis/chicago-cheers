#!/usr/bin/env sh
# Vercel installs from requirements.txt and has no Poetry support, so this
# regenerates it from poetry.lock. Run it after changing dependencies;
# lint.sh fails if requirements.txt has fallen out of step.
#
#   ./export-requirements.sh           rewrite requirements.txt
#   ./export-requirements.sh --stdout  print what it should contain

set -e
cd "$(dirname "$0")"

generate() {
  echo "# Generated from poetry.lock by export-requirements.sh, for Vercel. Do not edit."
  poetry export --format requirements.txt --only main --without-hashes
}

if [ "$1" = "--stdout" ]; then
  generate
else
  generate > requirements.txt
fi
