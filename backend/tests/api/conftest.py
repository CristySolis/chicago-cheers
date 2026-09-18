"""Shared setup for tests that run against a local Supabase stack. Run them
with ../integration-tests.sh after `npx supabase start`.

The API is exercised through HTTP exactly as the sender page and phone use
it. Supabase is only touched directly to create test runners and events,
which in production are set up by hand.
"""

import os
import struct
import uuid
from collections.abc import Callable
from decimal import Decimal as D
from typing import Any

import httpx
import psycopg
import pytest


def _local(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        pytest.exit(
            f"{name} is not set: run these through integration-tests.sh", returncode=2
        )
    return value


LOCAL = {
    name: _local(name) for name in ("API_URL", "ANON_KEY", "SERVICE_ROLE_KEY", "DB_URL")
}

# Must be set before the app is imported, since it reads them once.
os.environ.update(
    {
        "DATABASE_URL": LOCAL["DB_URL"],
        "SUPABASE_URL": LOCAL["API_URL"],
        "SUPABASE_SERVICE_KEY": LOCAL["SERVICE_ROLE_KEY"],
        "SUPABASE_ANON_KEY": LOCAL["ANON_KEY"],
    }
)

from fastapi.testclient import TestClient  # noqa: E402

from cheers.main import app  # noqa: E402

Runner = tuple[str, str]  # (their id, their access token)
EventRow = dict[str, Any]
MakeEvent = Callable[..., EventRow]

# Chicago: one spot per mile to 13, then one per half mile — 39 in all.
CHICAGO = [D(m) for m in range(1, 14)] + [D("13.5") + D("0.5") * i for i in range(26)]

ADMIN = {
    "Authorization": f"Bearer {LOCAL['SERVICE_ROLE_KEY']}",
    "apikey": LOCAL["SERVICE_ROLE_KEY"],
}


@pytest.fixture(scope="session")
def api() -> TestClient:
    return TestClient(app)


@pytest.fixture(scope="session")
def web() -> httpx.Client:
    """For talking to storage links directly, as a browser would."""
    return httpx.Client(timeout=10)


def new_runner() -> Runner:
    email, password = f"runner-{uuid.uuid4()}@test.local", str(uuid.uuid4())
    created = httpx.post(
        f"{LOCAL['API_URL']}/auth/v1/admin/users",
        headers=ADMIN,
        json={"email": email, "password": password, "email_confirm": True},
    )
    created.raise_for_status()
    signed_in = httpx.post(
        f"{LOCAL['API_URL']}/auth/v1/token?grant_type=password",
        headers={"apikey": LOCAL["ANON_KEY"]},
        json={"email": email, "password": password},
    )
    signed_in.raise_for_status()
    return str(created.json()["id"]), str(signed_in.json()["access_token"])


@pytest.fixture(scope="session")
def her() -> Runner:
    return new_runner()


@pytest.fixture(scope="session")
def other_runner() -> Runner:
    return new_runner()


@pytest.fixture
def make_event(her: Runner) -> MakeEvent:
    def make(owner: Runner | None = None, **overrides: Any) -> EventRow:
        row: EventRow = {
            "owner_id": (owner or her)[0],
            "name": "Chicago Marathon 2026",
            "unit": "mi",
            "slots": CHICAGO,
            "submissions_open": True,
            "share_code": uuid.uuid4().hex[:16],
            "runner_name": "Cristy",
            **overrides,
        }
        with psycopg.connect(LOCAL["DB_URL"]) as conn:
            inserted = conn.execute(
                "insert into events"
                " (owner_id, name, unit, slots, submissions_open, share_code, runner_name)"
                " values (%(owner_id)s, %(name)s, %(unit)s, %(slots)s, %(submissions_open)s,"
                " %(share_code)s, %(runner_name)s) returning id",
                row,
            ).fetchone()
        assert inserted is not None
        return {**row, "id": inserted[0]}

    return make


def age_claim(cheer_id: str, minutes: int) -> None:
    """Pretend a claim was made `minutes` ago."""
    with psycopg.connect(LOCAL["DB_URL"]) as conn:
        conn.execute(
            "update cheers set created_at = now() - make_interval(mins => %s) where id = %s",
            (minutes, cheer_id),
        )


def wav() -> bytes:
    """A real, minimal WAV of silence, so the bucket's type check is honest."""
    n = 800
    return (
        b"RIFF"
        + struct.pack("<I", 36 + n * 2)
        + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 16000, 2, 16)
        + b"data"
        + struct.pack("<I", n * 2)
        + b"\0" * (n * 2)
    )
