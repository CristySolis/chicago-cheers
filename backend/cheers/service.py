"""What supporters and runners can do, and the rules around it.

Knows nothing about Supabase, Vercel or HTTP — only the repository and the two
ports. That's what lets the hosting and providers change underneath it.
"""

from dataclasses import dataclass
from datetime import timedelta
from decimal import Decimal, InvalidOperation
from uuid import UUID

from cheers.allocation import rank_seats
from cheers.ports import IdentityVerifier, RecordingStore, RunnerSignIn, Session
from cheers.repository import Repository, SeatTaken

# How long a claim holds its seat while the recording uploads. Long enough for
# a slow phone connection; short enough that an abandoned browser tab doesn't
# keep a spot from someone else for long.
CLAIM_WINDOW = timedelta(minutes=15)


class CheerError(Exception):
    """A request the rules refuse. Each subclass maps to one HTTP response."""


class EventNotFound(CheerError): ...


class SubmissionsClosed(CheerError): ...


class NotASpot(CheerError): ...


class InvalidName(CheerError): ...


class EventFull(CheerError): ...


class NoPendingClaim(CheerError): ...


class RecordingMissing(CheerError): ...


class NotSignedIn(CheerError): ...


class BadCredentials(CheerError): ...


class SessionExpired(CheerError): ...


@dataclass(frozen=True)
class PublicEvent:
    """What a supporter sees: enough to choose a spot, never who is in one."""

    name: str
    runner_name: str | None
    unit: str
    slots: list[Decimal]
    submissions_open: bool
    occupancy: dict[Decimal, int]


@dataclass(frozen=True)
class Claim:
    cheer_id: UUID
    slot: Decimal
    upload_url: str


@dataclass(frozen=True)
class RunnerEvent:
    id: UUID
    name: str
    unit: str
    slots: list[Decimal]
    share_code: str


@dataclass(frozen=True)
class RunnerCheer:
    id: UUID
    slot: Decimal
    sender_name: str
    download_url: str


class CheerService:

    def __init__(
        self,
        repository: Repository,
        recordings: RecordingStore,
        identity: IdentityVerifier,
        sign_in: RunnerSignIn,
    ):
        self._repo = repository
        self._recordings = recordings
        self._identity = identity
        self._sign_in = sign_in

    # --- supporters ------------------------------------------------------------

    def public_event(self, share_code: str) -> PublicEvent:
        event = self._repo.event_by_code(share_code)
        if event is None:
            raise EventNotFound
        return PublicEvent(
            name=event.name,
            runner_name=event.runner_name,
            unit=event.unit,
            slots=event.slots,
            submissions_open=event.submissions_open,
            occupancy=self._repo.occupancy(event.id, CLAIM_WINDOW),
        )

    def claim(self, share_code: str, preferred: str, sender: str) -> Claim:
        event = self._repo.event_by_code(share_code)
        if event is None:
            raise EventNotFound
        if not event.submissions_open:
            raise SubmissionsClosed

        spot = _as_spot(preferred)
        if spot not in event.slots:
            raise NotASpot

        name = sender.strip()
        if not 1 <= len(name) <= 60:
            raise InvalidName

        self._repo.release_lapsed_claims(event.id, CLAIM_WINDOW)
        taken = self._repo.taken_seats(event.id)

        # Try seats best first. If two people race for the same one, the
        # database accepts one and the other simply moves to the next best —
        # which is why the ranking can come from a snapshot that's already
        # slightly stale.
        for slot, seat in rank_seats(event.slots, taken, spot):
            try:
                cheer_id = self._repo.take_seat(event.id, slot, seat, name)
            except SeatTaken:
                continue
            return Claim(
                cheer_id=cheer_id,
                slot=slot,
                upload_url=self._recordings.upload_url(
                    _recording_path(event.id, cheer_id)
                ),
            )

        raise EventFull

    def complete(self, cheer_id: UUID) -> Decimal:
        """Marks a claim finished once its recording is really in storage.
        Until then it's invisible to the runner."""
        cheer = self._repo.pending_claim(cheer_id, CLAIM_WINDOW)
        if cheer is None:
            raise NoPendingClaim

        path = _recording_path(cheer.event_id, cheer.id)
        if not self._recordings.exists(path):
            raise RecordingMissing

        self._repo.complete_claim(cheer.id, path)
        return cheer.slot

    # --- the runner ------------------------------------------------------------

    def sign_in(self, email: str, password: str) -> Session:
        session = self._sign_in.sign_in(email.strip(), password)
        if session is None:
            raise BadCredentials
        return session

    def refresh(self, refresh_token: str) -> Session:
        session = self._sign_in.refresh(refresh_token)
        if session is None:
            raise SessionExpired
        return session

    def runner_events(self, token: str | None) -> list[RunnerEvent]:
        runner = self._runner(token)
        return [
            RunnerEvent(e.id, e.name, e.unit, e.slots, e.share_code)
            for e in self._repo.owned_events(runner)
        ]

    def runner_cheers(self, token: str | None, event_id: UUID) -> list[RunnerCheer]:
        runner = self._runner(token)
        # Someone else's event looks exactly like one that doesn't exist, so
        # the answer can't be used to discover which events are real.
        if self._repo.owned_event(event_id, runner) is None:
            raise EventNotFound

        cheers = []
        for c in self._repo.finished_cheers(event_id):
            assert (
                c.audio_path is not None
            ), "finished_cheers returned one without audio"
            cheers.append(
                RunnerCheer(
                    c.id,
                    c.slot,
                    c.sender_name,
                    self._recordings.download_url(c.audio_path),
                )
            )
        return cheers

    def _runner(self, token: str | None) -> str:
        runner = self._identity.runner_id(token) if token else None
        if runner is None:
            raise NotSignedIn
        return runner


def _as_spot(value: str) -> Decimal:
    # Decimal from the string, not a float, so 20.5 compares equal to the
    # 20.5 stored as numeric rather than to 20.499999....
    try:
        return Decimal(str(value))
    except InvalidOperation:
        raise NotASpot from None


def _recording_path(event_id: UUID, cheer_id: UUID) -> str:
    return f"{event_id}/{cheer_id}.wav"
