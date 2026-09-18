"""Everything the service asks of the database, in plain SQL.

Talks to Postgres directly rather than through Supabase's API, so the same
code runs against Supabase today and Google Cloud SQL tomorrow — only the
connection string changes.
"""

from collections.abc import Iterator
from contextlib import contextmanager
from datetime import timedelta
from decimal import Decimal
from uuid import UUID

import psycopg
from psycopg.rows import class_row

from cheers.models import Cheer, Event


class SeatTaken(Exception):
    """Someone else holds the seat. Expected under contention, not an error."""


class Repository:

    def __init__(self, database_url: str):
        self._url = database_url

    @contextmanager
    def _connect(self) -> Iterator[psycopg.Connection]:
        # A connection per call suits serverless hosting, where nothing
        # survives between requests. prepare_threshold=None because hosted
        # connection poolers in transaction mode (Supabase's, and Cloud SQL
        # behind PgBouncer) break psycopg's automatic prepared statements.
        with psycopg.connect(self._url, prepare_threshold=None) as conn:
            yield conn

    # --- events ------------------------------------------------------------

    def event_by_code(self, share_code: str) -> Event | None:
        return self._one_event("share_code = %s", (share_code,))

    def owned_event(self, event_id: UUID, owner_id: str) -> Event | None:
        return self._one_event("id = %s and owner_id = %s", (event_id, owner_id))

    def owned_events(self, owner_id: str) -> list[Event]:
        with self._connect() as conn, conn.cursor(row_factory=class_row(Event)) as cur:
            cur.execute(
                f"select {_EVENT_COLUMNS} from events where owner_id = %s order by created_at",
                (owner_id,),
            )
            return cur.fetchall()

    def _one_event(self, where: str, args: tuple[object, ...]) -> Event | None:
        with self._connect() as conn, conn.cursor(row_factory=class_row(Event)) as cur:
            cur.execute(f"select {_EVENT_COLUMNS} from events where {where}", args)
            return cur.fetchone()

    # --- claiming ------------------------------------------------------------

    def release_lapsed_claims(self, event_id: UUID, window: timedelta) -> None:
        """Frees seats held by claims whose recording never arrived."""
        with self._connect() as conn:
            conn.execute(
                "delete from cheers where event_id = %s and audio_path is null"
                " and created_at < now() - %s",
                (event_id, window),
            )

    def taken_seats(self, event_id: UUID) -> set[tuple[Decimal, int]]:
        with self._connect() as conn:
            rows = conn.execute(
                "select slot, seat from cheers where event_id = %s",
                (event_id,),
            ).fetchall()
        return {(slot, seat) for slot, seat in rows}

    def take_seat(self, event_id: UUID, slot: Decimal, seat: int, sender: str) -> UUID:
        """Claims the seat, or raises SeatTaken if someone got there first.

        The one_person_per_seat constraint is what decides that, which is why
        simultaneous claims are safe without any locking here.
        """
        try:
            with self._connect() as conn:
                row = conn.execute(
                    "insert into cheers (event_id, slot, seat, sender_name)"
                    " values (%s, %s, %s, %s) returning id",
                    (event_id, slot, seat, sender),
                ).fetchone()
            assert row is not None, "insert ... returning produced no row"
            cheer_id: UUID = row[0]
            return cheer_id
        except psycopg.errors.UniqueViolation as e:
            if e.diag.constraint_name == "one_person_per_seat":
                raise SeatTaken from e
            raise

    def pending_claim(self, cheer_id: UUID, window: timedelta) -> Cheer | None:
        return self._one_cheer(
            "id = %s and audio_path is null and created_at > now() - %s",
            (cheer_id, window),
        )

    def complete_claim(self, cheer_id: UUID, audio_path: str) -> None:
        with self._connect() as conn:
            conn.execute(
                "update cheers set audio_path = %s where id = %s",
                (audio_path, cheer_id),
            )

    # --- reading back ----------------------------------------------------------

    def occupancy(self, event_id: UUID, window: timedelta) -> dict[Decimal, int]:
        """How many people hold each spot. Counts only — never names."""
        with self._connect() as conn:
            rows = conn.execute(
                "select slot, count(*) from cheers where event_id = %s"
                " and (audio_path is not null or created_at > now() - %s)"
                " group by slot",
                (event_id, window),
            ).fetchall()
        return {slot: count for slot, count in rows}

    def finished_cheers(self, event_id: UUID) -> list[Cheer]:
        with self._connect() as conn, conn.cursor(row_factory=class_row(Cheer)) as cur:
            cur.execute(
                f"select {_CHEER_COLUMNS} from cheers where event_id = %s"
                " and audio_path is not null order by slot, seat",
                (event_id,),
            )
            return cur.fetchall()

    def _one_cheer(self, where: str, args: tuple[object, ...]) -> Cheer | None:
        with self._connect() as conn, conn.cursor(row_factory=class_row(Cheer)) as cur:
            cur.execute(f"select {_CHEER_COLUMNS} from cheers where {where}", args)
            return cur.fetchone()


_EVENT_COLUMNS = "id, owner_id, name, unit, slots, submissions_open, share_code"
_CHEER_COLUMNS = "id, event_id, slot, seat, sender_name, audio_path, created_at"
