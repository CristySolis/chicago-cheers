-- Cheers: supporters claim a spot on a runner's course and record a message
-- that plays when the runner reaches it.
--
-- Everything hangs off an event (one runner, one race) so that several runners
-- can use this without any of them seeing another's cheers. Senders never get
-- table access: they reach an event only through its share code, and only via
-- the functions below, which report how full each spot is but never who is
-- in it.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.events (
    id uuid primary key default gen_random_uuid(),
    owner_id uuid not null references auth.users (id) on delete cascade,
    name text not null,
    race_date date,

    -- Where a cheer can be placed, measured in `unit`. Per event because other
    -- races have other distances; Chicago is one per mile to 13, then one per
    -- half mile.
    unit text not null default 'mi' check (unit in ('mi', 'km')),
    slots numeric[] not null check (cardinality(slots) > 0),

    -- Stops the strip being flooded. Twice the slot count is every spot
    -- doubled up, which is the most the claiming rules ever produce.
    max_cheers integer not null check (max_cheers > 0),
    submissions_open boolean not null default true,

    -- The only handle a sender has on an event, carried in the link.
    share_code text not null unique
        default encode(extensions.gen_random_bytes(8), 'hex'),

    created_at timestamptz not null default now()
);

create table public.cheers (
    id uuid primary key default gen_random_uuid(),
    event_id uuid not null references public.events (id) on delete cascade,
    slot numeric not null,
    sender_name text not null
        check (char_length(btrim(sender_name)) between 1 and 60),

    -- Null until the recording has actually uploaded. A claim without audio is
    -- a reservation, not a cheer, and must never reach the runner's phone.
    audio_path text,

    created_at timestamptz not null default now()
);

create index cheers_event_slot on public.cheers (event_id, slot);

-- ---------------------------------------------------------------------------
-- What counts as "taken"
-- ---------------------------------------------------------------------------

-- A spot is occupied by a finished cheer, or by a claim still within its
-- window to upload. Claims must count while pending — otherwise two people
-- recording at once would both be told a spot is free — but an abandoned
-- claim has to lapse, or a closed browser tab would hold a spot forever.
create function public.occupies_slot(c public.cheers)
returns boolean
language sql
stable
set search_path = ''
as $$
    select c.audio_path is not null
        or c.created_at > now() - interval '15 minutes';
$$;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.events enable row level security;
alter table public.cheers enable row level security;

-- Runners read their own events and cheers. There are deliberately no
-- policies for anon: senders go through the functions below instead.
create policy "owners read their events"
    on public.events for select to authenticated
    using (owner_id = (select auth.uid()));

create policy "owners read their cheers"
    on public.cheers for select to authenticated
    using (exists (
        select 1 from public.events e
        where e.id = cheers.event_id
          and e.owner_id = (select auth.uid())
    ));

-- ---------------------------------------------------------------------------
-- Sender-facing functions
-- ---------------------------------------------------------------------------

-- What the sender page needs to draw itself. No owner, no names.
create function public.event_for_share_code(code text)
returns table (
    event_id uuid,
    name text,
    unit text,
    slots numeric[],
    submissions_open boolean
)
language sql
stable
security definer
set search_path = ''
as $$
    select e.id, e.name, e.unit, e.slots, e.submissions_open
    from public.events e
    where e.share_code = code;
$$;

-- How many cheers sit on each spot, so the strip can show taken and free.
-- Counts only: this is what keeps senders anonymous from one another.
create function public.slot_occupancy(code text)
returns table (slot numeric, cheers integer)
language sql
stable
security definer
set search_path = ''
as $$
    select c.slot, count(*)::integer
    from public.cheers c
    join public.events e on e.id = c.event_id
    where e.share_code = code
      and public.occupies_slot(c)
    group by c.slot;
$$;

-- Claims a spot for a sender, returning the cheer to upload against and the
-- spot actually assigned — which may differ from the one asked for.
--
-- The rules, in order:
--   1. The spot asked for, if nobody holds it.
--   2. Otherwise the next free spot after it, then the nearest free one
--      before it. Nobody doubles up while any spot is still free.
--   3. Once every spot is held, double up on the least crowded, nearest to
--      the one asked for.
create function public.claim_slot(code text, preferred numeric, sender text)
returns table (cheer_id uuid, assigned_slot numeric)
language plpgsql
security definer
set search_path = ''
as $$
declare
    ev public.events%rowtype;
    held integer;
    chosen numeric;
begin
    -- Locking the event serialises every claim against it. Without this, two
    -- people tapping the same mile in the same instant would each read it as
    -- free and both take it.
    select * into ev
    from public.events
    where share_code = code
    for update;

    if not found then
        raise exception 'unknown event';
    end if;
    if not ev.submissions_open then
        raise exception 'submissions are closed';
    end if;
    if not (preferred = any (ev.slots)) then
        raise exception 'not a spot on this course';
    end if;

    select count(*) into held
    from public.cheers c
    where c.event_id = ev.id
      and public.occupies_slot(c);

    if held >= ev.max_cheers then
        raise exception 'this event is full';
    end if;

    select s.slot into chosen
    from unnest(ev.slots) as s (slot)
    left join public.cheers c
           on c.event_id = ev.id
          and c.slot = s.slot
          and public.occupies_slot(c)
    group by s.slot
    order by
        count(c.id),                    -- free before held; then least doubled
        (s.slot < preferred),           -- at or after the choice, before earlier
        abs(s.slot - preferred)         -- nearest first
    limit 1;

    return query
    insert into public.cheers (event_id, slot, sender_name)
    values (ev.id, chosen, btrim(sender))
    returning public.cheers.id, public.cheers.slot;
end;
$$;

-- Marks a claim complete once its recording is really in storage. Until this
-- runs, the cheer is invisible to the runner's phone.
create function public.attach_audio(the_cheer uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    path text;
begin
    select c.event_id::text || '/' || c.id::text || '.wav' into path
    from public.cheers c
    where c.id = the_cheer
      and c.audio_path is null
      and c.created_at > now() - interval '15 minutes';

    if path is null then
        raise exception 'no pending claim for that cheer';
    end if;

    if not exists (
        select 1 from storage.objects o
        where o.bucket_id = 'cheers' and o.name = path
    ) then
        raise exception 'recording has not been uploaded';
    end if;

    update public.cheers set audio_path = path where id = the_cheer;
end;
$$;

-- ---------------------------------------------------------------------------
-- Recordings
-- ---------------------------------------------------------------------------

-- Private: only an event's owner can download its recordings. WAV only,
-- because browsers record in formats iPhones can't all play, so the page
-- encodes WAV itself. 1.5 MB comfortably holds 25 seconds of speech.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cheers', 'cheers', false, 1572864, array['audio/wav']);

-- Storage policies run as the caller, and anon can't read public.cheers, so a
-- policy that queried it directly would silently deny every upload. The check
-- therefore lives in a security definer function.
create function public.is_pending_upload(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.cheers c
        join public.events e on e.id = c.event_id
        where object_name = c.event_id::text || '/' || c.id::text || '.wav'
          and c.audio_path is null
          and c.created_at > now() - interval '15 minutes'
          and e.submissions_open
    );
$$;

-- A sender may upload exactly one file: to the path of their own pending
-- claim. Anywhere else, or a second time, is refused. With no update policy,
-- nothing can be overwritten either.
create policy "senders upload to their pending claim"
    on storage.objects for insert to anon, authenticated
    with check (
        bucket_id = 'cheers'
        and public.is_pending_upload(objects.name)
    );

create policy "owners download their recordings"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'cheers'
        and exists (
            select 1 from public.events e
            where e.id::text = (storage.foldername(objects.name))[1]
              and e.owner_id = (select auth.uid())
        )
    );

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------

revoke execute on function
    public.event_for_share_code(text),
    public.slot_occupancy(text),
    public.claim_slot(text, numeric, text),
    public.attach_audio(uuid),
    public.is_pending_upload(text)
from public;

grant execute on function
    public.event_for_share_code(text),
    public.slot_occupancy(text),
    public.claim_slot(text, numeric, text),
    public.attach_audio(uuid),
    public.is_pending_upload(text)
to anon, authenticated;
