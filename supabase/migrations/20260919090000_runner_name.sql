-- The name supporters see on the sender page: "Record a cheer for Cristy".
--
-- Nullable and added without a default, so code that doesn't know about it
-- keeps working. That matters for the order of a deploy: this runs first, and
-- the API that reads it ships afterwards.
alter table public.events add column runner_name text
    check (runner_name is null or char_length(btrim(runner_name)) between 1 and 60);
