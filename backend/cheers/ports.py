"""What the service needs from the outside world, and nothing about who provides it.

The core logic depends only on these. Supabase implements them today
(`cheers.adapters.supabase`); moving to Google Cloud means writing a version of
each against Cloud Storage and Firebase Auth, and nothing else in the service
changes. The database needs no such seam: it's plain Postgres, which Cloud SQL
also is.
"""

from dataclasses import dataclass
from typing import Protocol


class RecordingStore(Protocol):
    """Where recordings live. Nobody ever gets standing access to it: senders
    receive a link that uploads one file to one place, and the runner receives
    links that download her own recordings, each for a limited time."""

    def upload_url(self, path: str) -> str:
        """A link that accepts one plain PUT of a WAV file to `path`, and
        refuses to overwrite anything already there."""
        ...

    def exists(self, path: str) -> bool: ...

    def download_url(self, path: str) -> str:
        """A time-limited link that plays the recording at `path`."""
        ...


class IdentityVerifier(Protocol):
    """Turns the runner's sign-in token into the id her events are stored under."""

    def runner_id(self, token: str) -> str | None:
        """The runner's id, or None if the token isn't valid."""
        ...


@dataclass(frozen=True)
class Session:
    access_token: str
    refresh_token: str
    expires_in: int  # seconds until access_token stops working


class RunnerSignIn(Protocol):
    """Signs the runner in on her phone's behalf, so the phone talks only to
    this API and never to the login provider directly."""

    def sign_in(self, email: str, password: str) -> Session | None:
        """A new session, or None if the email and password don't match."""
        ...

    def refresh(self, refresh_token: str) -> Session | None:
        """A fresh session, or None if the refresh token is no longer valid.

        The returned refresh token replaces the one passed in; providers may
        revoke the whole session if a replaced token is ever used again.
        """
        ...
