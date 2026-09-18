-- Cheers: supporters claim a spot on a runner's course and record a message
-- that plays when the runner reaches it.
--
-- Plain Postgres, deliberately. Every behaviour lives in the Python API; this
-- file holds only structure, plus the one rule the database has to enforce
-- itself because nothing else can see every claim at once — that a seat can't
-- be held twice. Nothing here depends on Supabase, so it runs unchanged on
-- Google Cloud SQL.

create table public.events (
    id uuid primary key default gen_random_uuid(),

    -- The runner's id from whichever login provider is in use. Plain text
    -- rather than a reference to Supabase's own users table, so changing
    -- providers doesn't mean restructuring.
    owner_id text not null,

    name text not null,
    race_date date,

    -- Where a cheer can be placed, measured in `unit`. Per event because other
    -- races have other distances.
    unit text not null default 'mi' check (unit in ('mi', 'km')),
    slots numeric[] not null check (cardinality(slots) > 0),

    submissions_open boolean not null default true,

    -- The only handle a sender has on an event, carried in their link.
    share_code text not null unique,

    created_at timestamptz not null default now()
);

create index events_owner on public.events (owner_id);

create table public.cheers (
    id uuid primary key default gen_random_uuid(),
    event_id uuid not null references public.events (id) on delete cascade,
    slot numeric not null,

    -- Each spot has two seats: the first person, and whoever doubles up once
    -- every spot is taken. Two seats per spot also caps an event at twice its
    -- spots, with no separate limit to keep in step.
    seat smallint not null check (seat in (1, 2)),

    sender_name text not null
        check (char_length(btrim(sender_name)) between 1 and 60),

    -- Null until the recording has uploaded. A claim without audio is a
    -- reservation, not a cheer, and must never reach the runner's phone.
    audio_path text,

    created_at timestamptz not null default now(),

    -- The rule that makes simultaneous claims safe. Two people racing for the
    -- same seat both try to take it; the database accepts one and refuses the
    -- other, who moves on to the next best seat.
    constraint one_person_per_seat unique (event_id, slot, seat)
);

-- Supabase publishes every table through an automatic web API. Row level
-- security with no policies closes that door, so the Python API is the only
-- way in and its rules can't be walked around. On Cloud SQL there is no such
-- API, and this is simply inert.
alter table public.events enable row level security;
alter table public.cheers enable row level security;
