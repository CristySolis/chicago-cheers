"""What the service needs from the outside world, and nothing about who provides it.

The core logic depends only on these. Supabase implements them today
(`cheers.adapters.supabase`); moving to Google Cloud means writing a version of
each against Cloud Storage and Firebase Auth, and nothing else in the service
changes. The database needs no such seam: it's plain Postgres, which Cloud SQL
also is.
"""

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
