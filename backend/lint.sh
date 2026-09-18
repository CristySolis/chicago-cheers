#!/usr/bin/env sh
set -e
cd "$(dirname "$0")"

poetry check

if ! ./export-requirements.sh --stdout | diff -q - requirements.txt > /dev/null; then
  echo "requirements.txt is out of date: run ./export-requirements.sh" >&2
  exit 1
fi

poetry run lint-imports
poetry run black --check .
poetry run isort --check .
poetry run mypy
poetry run pytest
