"""Where the service's settings and providers come from.

`build_service` is the single place that chooses Supabase. Moving to Google
Cloud means changing what it constructs — Cloud SQL's connection string, and
Cloud Storage and Firebase Auth adapters — and nothing else.
"""

import os
from dataclasses import dataclass

import httpx

from cheers.adapters.supabase import (
    SupabaseIdentityVerifier,
    SupabaseRecordingStore,
    SupabaseRunnerSignIn,
)
from cheers.repository import Repository
from cheers.service import CheerService


@dataclass(frozen=True)
class Settings:
    database_url: str
    supabase_url: str
    supabase_service_key: str
    supabase_anon_key: str
    recordings_bucket: str

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            database_url=_required("DATABASE_URL"),
            supabase_url=_required("SUPABASE_URL"),
            supabase_service_key=_required("SUPABASE_SERVICE_KEY"),
            supabase_anon_key=_required("SUPABASE_ANON_KEY"),
            recordings_bucket=os.environ.get("RECORDINGS_BUCKET", "cheers"),
        )


def build_service(settings: Settings) -> CheerService:
    http = httpx.Client(timeout=10)
    return CheerService(
        repository=Repository(settings.database_url),
        recordings=SupabaseRecordingStore(
            settings.supabase_url,
            settings.supabase_service_key,
            settings.recordings_bucket,
            http,
        ),
        identity=SupabaseIdentityVerifier(
            settings.supabase_url, settings.supabase_anon_key, http
        ),
        sign_in=SupabaseRunnerSignIn(
            settings.supabase_url, settings.supabase_anon_key, http
        ),
    )


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is not set")
    return value
