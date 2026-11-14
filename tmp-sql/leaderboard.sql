-- Cursewake leaderboard ("Ranglista"). Apply by hand in the Supabase SQL editor, after schema.sql, admin.sql
-- and events-limit.sql. Safe to run more than once, also on a database that has an earlier version of this file:
-- every table and index is "if not exists" (new columns "add column if not exists"), every function dropped or
-- "create or replace"d, every policy and trigger dropped and made again, the backfill at the end skips what it has.
--
-- How it works (the long version is in README.md, "Ranglista"):
-- - Nothing a player sends is a score. Every accepted cloud save (insert or update of public.saves.data, which only
--   save_game may do: schema.sql) runs the trigger lb_on_save, which reads the heroes out of the save and keeps one
--   row per hero (lb_entries). If anything in that goes wrong, the save is still written (the error goes to lb_flags).
-- - Plausibility checks run on the server, see lb_ingest. An entry that fails is kept (so an admin can look at it)
--   but hidden ("under review" for its owner), and the reason goes to lb_flags. A hero the server sees for the first
--   time already far along (an old local save uploaded) is hidden until an admin looks, and so is one that first
--   reaches the top (level 90, floor 150, its stamped first Hell clear: 'review_top'). An admin's approval is a new
--   starting point for the checks, not a permanent pass. A fallen hardcore hero keeps its last entry, marked as fallen.
-- - The first Hell clear is stamped with the server's clock the first time a save holding it is accepted (lb_firsts),
--   and only if Nightmare was seen done at least 2 hours earlier.
-- - Seasons are calendar months in Hungarian time (Europe/Budapest). lb_season keeps, per month, the new records a
--   hero set in that month (a new deepest floor, a new level, the first Hell clear). Past months are never written
--   again, so the hall of fame (lb_hall: the top 10 of every past month and board, of which the first 3 still
--   visible are shown) can be frozen whenever it is first needed: by the first hall-of-fame read of a new month that
--   gets the lock. Saves never wait for it; a reader that does not get the lock is served the same thing unfrozen.
-- - Anyone (also signed-out visitors) may read the boards through lb_board / lb_hall; neither ever shows a user id:
--   a hero is known by an opaque id (pid: an HMAC of user id + hero id with a secret kept in lb_secret). Names: the
--   public nickname the player set, else a guest number ("Vándor #123456" in the game). Never the Discord name.
-- - Admins (public.is_admin()) list entries and flags, hide or show an entry and ban a player from the boards.
--   Admins' own heroes are not on the public boards (they see their own rows, marked).

begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------------ old versions out of the way
-- Functions whose result type changed since the first version (create or replace cannot change it).
drop function if exists public.lb_freeze_seasons();
drop function if exists public.lb_ranked(text, text, boolean, text, text);
drop function if exists public.admin_lb_entries(text, int);

-- ------------------------------------------------------------------ helpers (pure functions)

-- Experience needed for the next level: the same formula as B.xp.toNext in src/content/balance.js.
create or replace function public.lb_to_next(p_level int)
returns numeric
language sql
immutable
set search_path = public
as $$
  select round((45 * power(p_level::numeric, 2) + 70 * p_level)
               * (1 + greatest(0, p_level - 50) * 0.012 + greatest(0, p_level - 70) * 0.08));
$$;

-- The deepest Depths floor a hero of this level is believed able to reach (generous, see LB.depthCap in
-- src/client/ranks-core.js and README): the simulator's level-55 heroes reach about floor 25-30 and its
-- level-86 heroes about 55-67; the bound is roughly twice that.
create or replace function public.lb_depth_cap(p_level int)
returns int
language sql
immutable
set search_path = public
as $$
  select greatest(10, 3 * p_level - 60);
$$;

-- The season a moment belongs to: its calendar month in Hungarian time, as 'YYYY-MM'.
create or replace function public.lb_season_of(p_at timestamptz)
returns text
language sql
stable
set search_path = public
as $$
  select to_char(p_at at time zone 'Europe/Budapest', 'YYYY-MM');
$$;

-- The season before the one a moment belongs to.
create or replace function public.lb_prev_season(p_at timestamptz)
returns text
language sql
stable
set search_path = public
as $$
  select to_char(date_trunc('month', p_at at time zone 'Europe/Budapest') - interval '1 day', 'YYYY-MM');
$$;

-- A name as the word filter sees it: accents, ı/İ and look-alike digits folded, lower case, everything but a-z
-- dropped. The same folding as normalizeForFilter in src/client/ranks-core.js (folded before and after lower(), so
-- it does not depend on how the database lower-cases non-ASCII letters).
create or replace function public.lb_fold(p text)
returns text
language sql
immutable
set search_path = public
as $$
  select regexp_replace(
           translate(lower(translate(coalesce(p, ''),
                                     'áéíóöőúüűàâäãåçèêëìîïñòôõøùûýÿÁÉÍÓÖŐÚÜŰıİ013457@$',
                                     'aeiooouuuaaaaaceeeiiinoooouuyyaeiooouuuiioieastas')),
                     'áéíóöőúüűàâäãåçèêëìîïñòôõøùûýÿÁÉÍÓÖŐÚÜŰıİ013457@$',
                     'aeiooouuuaaaaaceeeiiinoooouuyyaeiooouuuiioieastas'),
           '[^a-z]', '', 'g');
$$;

-- A nickname's skeleton, for uniqueness: folded like lb_fold (accents, case, ı/İ, look-alike digits), l and i
-- counted as one, separators (space . _ -) dropped, other digits kept. "Geri", "Géri", "GERİ", "Ger1" and "Ge.ri"
-- are one name. The same as nickSkeleton in src/client/ranks-core.js.
create or replace function public.lb_skel(p text)
returns text
language sql
immutable
set search_path = public
as $$
  select regexp_replace(
           translate(translate(lower(translate(coalesce(p, ''),
                                               'áéíóöőúüűàâäãåçèêëìîïñòôõøùûýÿÁÉÍÓÖŐÚÜŰıİ013457@$',
                                               'aeiooouuuaaaaaceeeiiinoooouuyyaeiooouuuiioieastas')),
                               'áéíóöőúüűàâäãåçèêëìîïñòôõøùûýÿÁÉÍÓÖŐÚÜŰıİ013457@$',
                               'aeiooouuuaaaaaceeeiiinoooouuyyaeiooouuuiioieastas'),
                     'l', 'i'),
           '[^a-z0-9]', '', 'g');
$$;

-- The only characters a public name may have (nicknames, and hero names to be shown): English letters, the Hungarian
-- accented ones, digits, space, dot, underscore, hyphen. The same as NAME_CHARS in src/client/ranks-core.js.
create or replace function public.lb_name_chars_ok(p text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select coalesce(p, '') ~ '^[A-Za-z0-9áéíóöőúüűÁÉÍÓÖŐÚÜŰ _.-]*$';
$$;

-- A light word filter for public names (nicknames and hero names), on the folded name. Kept short on purpose: it
-- stops the obvious, an admin hides the rest. The same list as BAD_WORDS in src/client/ranks-core.js (a test keeps
-- them equal). Since a shown name may only have the characters above, the folding covers every letter it can hold.
create or replace function public.lb_bad_name(p text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select exists (
    select 1 from unnest(array[
      -- lb-bad-words:start
      'fasz', 'geci', 'kurva', 'buzi', 'kocsog', 'picsa', 'baszd', 'bassz', 'baszo', 'anyad', 'csicska', 'punci',
      'fuck', 'cunt', 'nigg', 'bitch', 'whore', 'hitler', 'nazi', 'retard', 'fagg', 'porn'
      -- lb-bad-words:end
    ]) w where position(w in public.lb_fold(p)) > 0);
$$;

-- A hero name as it may be shown: no control or direction characters, at most 16 characters; a name with any other
-- character than lb_name_chars_ok allows, or a rude one, is emptied (the game then shows the hero's class).
create or replace function public.lb_clean_hero_name(p text)
returns text
language sql
immutable
set search_path = public
as $$
  select case when not public.lb_name_chars_ok(n) or public.lb_bad_name(n) then '' else n end
    from (select btrim(left(regexp_replace(coalesce(p, ''), '[[:cntrl:]\u200B-\u200F\u2028-\u202E\u2060-\u2069\uFEFF]', '', 'g'), 16)) as n) x;
$$;

-- An ISO time the game wrote (hero.firsts.hellClearAt), or null if it is not one. Never raises.
create or replace function public.lb_iso_time(p text)
returns timestamptz
language plpgsql
immutable
set search_path = public
as $$
begin
  if p is null or p !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' then
    return null;
  end if;
  return p::timestamptz;
exception when others then
  return null;
end;
$$;

-- ------------------------------------------------------------------ tables

-- The secret behind the public hero ids (one row, made once, readable by nobody but the owner).
create table if not exists public.lb_secret (
  id smallint primary key default 1 check (id = 1),
  key text not null
);
alter table public.lb_secret enable row level security;
revoke all on public.lb_secret from public, anon, authenticated;
insert into public.lb_secret (id, key) values (1, encode(extensions.gen_random_bytes(32), 'hex')) on conflict (id) do nothing;

-- The opaque public id of a hero: an HMAC of user id and hero id with the secret, so it is stable, never the user id,
-- and cannot be worked out (or checked against a guessed user id) without the secret.
create or replace function public.lb_pid(p_user uuid, p_hero text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select left(encode(extensions.hmac(p_user::text || ':' || p_hero, (select s.key from public.lb_secret s where s.id = 1), 'sha256'), 'hex'), 20);
$$;

-- Public name of a player (lb_profiles, so as not to clash with a 'profiles' table a Supabase template may have made):
-- the nickname they set (nick_skel: its skeleton, unique), and their guest number (6 digits, unique, given once).
-- Each player reads only their own row; writing goes through set_nickname and the functions below.
create table if not exists public.lb_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  nickname text check (nickname is null or char_length(nickname) between 3 and 16),
  updated_at timestamptz not null default now()
);
alter table public.lb_profiles add column if not exists guest_no int, add column if not exists nick_skel text, add column if not exists nick_at timestamptz;
alter table public.lb_profiles drop constraint if exists lb_profiles_guest_no_check;
alter table public.lb_profiles add constraint lb_profiles_guest_no_check check (guest_no is null or guest_no between 100000 and 999999);
create unique index if not exists lb_profiles_nickname_uq on public.lb_profiles (lower(nickname)) where nickname is not null;
create unique index if not exists lb_profiles_skel_uq on public.lb_profiles (nick_skel) where nickname is not null;
create unique index if not exists lb_profiles_guest_no_uq on public.lb_profiles (guest_no);
update public.lb_profiles set nick_skel = public.lb_skel(nickname) where nickname is not null and nick_skel is distinct from public.lb_skel(nickname);
alter table public.lb_profiles enable row level security;
drop policy if exists "lb_profiles: read own" on public.lb_profiles;
create policy "lb_profiles: read own" on public.lb_profiles for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.lb_profiles from anon, authenticated;
grant select on public.lb_profiles to authenticated;

-- One row per hero ever seen in an accepted cloud save.
create table if not exists public.lb_entries (
  user_id uuid not null references auth.users (id) on delete cascade,
  hero_id text not null check (hero_id ~ '^[A-Za-z0-9_-]{1,40}$'),
  pid text not null unique,
  hero_name text not null default '',
  class_id text not null,
  hardcore boolean not null,
  level int not null default 1,
  xp bigint not null default 0,
  level_at timestamptz not null default now(),   -- when the server first saw this level
  deepest int not null default 0,
  deepest_at timestamptz,                        -- when the server first saw this deepest floor
  hell_clear_at timestamptz,                     -- server time of the first accepted save with Hell cleared
  fallen boolean not null default false,         -- a hardcore hero that died: its entry stays as it was
  fallen_at timestamptz,
  hidden boolean not null default false,         -- not on the public boards (failed a check, an admin hid it, the save was deleted)
  hidden_reason text,                            -- 'auto:<check>', 'auto:save_gone' or 'admin'
  admin_ok boolean not null default false,       -- an admin showed it: the state they saw is not hidden again for the same reasons
  first_seen timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, hero_id)
);
-- The starting point of the growth-rate checks (first sight, or the last admin approval), when Nightmare was first
-- seen done, and whether the hero came in with the one-off backfill (old saves: no first-sight or Hell-timing checks).
alter table public.lb_entries add column if not exists rate_from timestamptz, add column if not exists rate_level int,
  add column if not exists rate_deepest int, add column if not exists nm_at timestamptz, add column if not exists legacy boolean not null default false;
update public.lb_entries set rate_from = now(), rate_level = level, rate_deepest = deepest where rate_from is null;
-- Index-driven boards (lb_board reads the top N in index order): only visible entries are in them.
drop index if exists public.lb_entries_depth_idx;
drop index if exists public.lb_entries_level_idx;
drop index if exists public.lb_entries_hell_idx;
create index if not exists lb_entries_depth2_idx on public.lb_entries (hardcore, deepest desc, deepest_at, pid) where deepest > 0 and not hidden;
create index if not exists lb_entries_level2_idx on public.lb_entries (hardcore, level desc, xp desc, level_at, pid) where not hidden;
create index if not exists lb_entries_hell2_idx on public.lb_entries (hardcore, hell_clear_at, pid) where hell_clear_at is not null and not hidden;
create index if not exists lb_entries_hero_idx on public.lb_entries (hero_id);

-- Firsts, stamped by the server's clock (client_at: what the game said, kept for reference only).
create table if not exists public.lb_firsts (
  user_id uuid not null,
  hero_id text not null,
  kind text not null check (kind in ('hell_clear')),
  at timestamptz not null default now(),
  client_at timestamptz,
  primary key (user_id, hero_id, kind),
  foreign key (user_id, hero_id) references public.lb_entries (user_id, hero_id) on delete cascade
);

-- The new records a hero set in one season (calendar month, Hungarian time). Only the current month is ever written.
create table if not exists public.lb_season (
  season text not null check (season ~ '^\d{4}-\d{2}$'),
  user_id uuid not null,
  hero_id text not null,
  deepest int,
  deepest_at timestamptz,
  level int,
  level_at timestamptz,
  hell_clear_at timestamptz,
  primary key (season, user_id, hero_id),
  foreign key (user_id, hero_id) references public.lb_entries (user_id, hero_id) on delete cascade
);
create index if not exists lb_season_depth_idx on public.lb_season (season, deepest desc, deepest_at) where deepest is not null;
create index if not exists lb_season_level_idx on public.lb_season (season, level desc, level_at) where level is not null;
create index if not exists lb_season_hell_idx on public.lb_season (season, hell_clear_at) where hell_clear_at is not null;

-- Hall of fame: the top 10 of every board of every finished season, frozen once. What is shown is worked out when it
-- is read: entries hidden or players banned since drop out, the rest move up (the first 3 shown), names are current.
create table if not exists public.lb_hall (
  season text not null,
  board text not null check (board in ('depth', 'level', 'hell')),
  hardcore boolean not null,
  class_filter text not null default '',          -- '' = all classes
  place int not null,
  user_id uuid not null,
  hero_id text not null,
  pid text not null,
  hero_name text not null default '',
  class_id text not null,
  value int,
  value_at timestamptz,
  primary key (season, board, hardcore, class_filter, place)
);
alter table public.lb_hall drop constraint if exists lb_hall_place_check;
alter table public.lb_hall add constraint lb_hall_place_check check (place between 1 and 10);
create table if not exists public.lb_hall_done (
  season text primary key,
  frozen_at timestamptz not null default now()
);

-- What the checks found, and what admins did (reason 'admin_hide', 'admin_show', 'admin_ban', 'admin_unban').
create table if not exists public.lb_flags (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  user_id uuid not null references auth.users (id) on delete cascade,
  hero_id text,
  reason text not null,
  hid boolean not null default false,
  detail jsonb not null default '{}'::jsonb
);
create index if not exists lb_flags_at_idx on public.lb_flags (at desc);
create index if not exists lb_flags_hero_idx on public.lb_flags (user_id, hero_id, reason, at desc);
create index if not exists lb_flags_user_idx on public.lb_flags (user_id, at desc);

-- Players kept off every board (their saves are still read, so nothing is lost if the ban is lifted).
create table if not exists public.lb_bans (
  user_id uuid primary key references auth.users (id) on delete cascade,
  reason text not null default '',
  at timestamptz not null default now(),
  by_user uuid
);

-- No direct access for players: only the functions below read or write these.
alter table public.lb_entries enable row level security;
alter table public.lb_firsts enable row level security;
alter table public.lb_season enable row level security;
alter table public.lb_hall enable row level security;
alter table public.lb_hall_done enable row level security;
alter table public.lb_flags enable row level security;
alter table public.lb_bans enable row level security;
revoke all on public.lb_entries, public.lb_firsts, public.lb_season, public.lb_hall, public.lb_hall_done, public.lb_flags, public.lb_bans from anon, authenticated;
revoke all on sequence public.lb_flags_id_seq from public, anon, authenticated;

-- Public ids made with the old (unsalted md5) formula are made again with the secret.
update public.lb_entries set pid = public.lb_pid(user_id, hero_id) where pid is distinct from public.lb_pid(user_id, hero_id);
update public.lb_hall set pid = public.lb_pid(user_id, hero_id) where pid is distinct from public.lb_pid(user_id, hero_id);

-- ------------------------------------------------------------------ names

-- Gives a player their guest number (6 digits, random, unique) the first time they need one.
create or replace function public.lb_ensure_profile(p_user uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  tries int := 0;
begin
  if p_user is null or exists (select 1 from public.lb_profiles p where p.user_id = p_user and p.guest_no is not null) then
    return;
  end if;
  loop
    tries := tries + 1;
    begin
      insert into public.lb_profiles as p (user_id, guest_no) values (p_user, 100000 + floor(random() * 900000)::int)
      on conflict (user_id) do update set guest_no = excluded.guest_no where p.guest_no is null;
      return;
    exception when unique_violation then
      if tries >= 25 then raise; end if;  -- the number was taken: draw again
    end;
  end loop;
end;
$$;

-- How a player is shown: the nickname they set, else their guest number. (Never the Discord name: a player shows
-- that only by choosing it as their nickname.)
create or replace function public.lb_player(p_user uuid, out name text, out kind text, out guest_no int)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  nick text;
  g int;
begin
  select p.nickname, p.guest_no into nick, g from public.lb_profiles p where p.user_id = p_user;
  if nick is not null then
    name := nick;
    kind := 'nick';
    return;
  end if;
  name := '';
  kind := 'guest';
  -- Everyone with an entry has a number (lb_ingest); the hash is only a stand-in that never shows a user id.
  guest_no := coalesce(g, 100000 + (('x' || substr(md5('cw-guest:' || p_user::text), 1, 8))::bit(32)::bigint % 900000)::int);
end;
$$;

revoke all on function public.lb_to_next(int), public.lb_depth_cap(int), public.lb_season_of(timestamptz), public.lb_prev_season(timestamptz),
  public.lb_fold(text), public.lb_skel(text), public.lb_name_chars_ok(text), public.lb_bad_name(text), public.lb_clean_hero_name(text),
  public.lb_pid(uuid, text), public.lb_iso_time(text), public.lb_ensure_profile(uuid), public.lb_player(uuid) from public, anon, authenticated;
drop function if exists public.lb_guest_no(uuid);

-- ------------------------------------------------------------------ reading a save (the trigger)

-- Reads every hero of an accepted save into lb_entries (and lb_season, lb_firsts, lb_flags).
-- p_at: when it was accepted (now(); the backfill passes the save's own time). p_backfill: the one-off fill at the
-- end of this file (the season it counts for is the current one; heroes from it are "legacy": nothing there is a
-- first-sight jump, and their Hell clears are not timed against Nightmare).
--
-- The checks (an entry failing one is hidden; the same numbers as LB in src/client/ranks-core.js):
--   level 1-99; experience inside the level; a deepest floor 0-9999, only after Normal, at most lb_depth_cap(level);
--   Hell only after Normal and Nightmare and at level 70 or more (the simulator clears Hell at about level 80-88);
--   class and hardcore never change; first sight (not backfill) of a hero past level 30, in the Depths, or past
--   Nightmare (an old local save uploaded: an admin looks); the same hero id in another account (a copied save).
--   Growth, between two saves and in all since the starting point (first sight / admin approval), see below.
-- Not hiding: a Hell clear less than 2 hours after Nightmare was first seen done is not accepted yet (no stamp; a
-- later save stamps it), and is noted. Limits: the first 3 slots only (the game has 3), at most 30 heroes ever per
-- account, at most 20 flag lines per account an hour.
create or replace function public.lb_ingest(p_user uuid, p_data jsonb, p_at timestamptz default now(), p_backfill boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season text := public.lb_season_of(case when p_backfill then now() else p_at end);
  final_zone constant text := 'world_heart';  -- content.zoneOrder.at(-1): the last boss of every difficulty
  classes constant text[] := array['reaver', 'elementalist', 'gravecaller', 'ranger', 'templar'];
  hero_slots constant int := 3;               -- HERO_SLOTS in src/client/api.js
  max_entries constant int := 30;             -- heroes ever kept per account
  max_flags_hour constant int := 20;          -- flag lines per account an hour
  hell_min_level constant int := 70;
  hell_after_nm constant interval := interval '2 hours';
  -- Growth limits. Between two saves (what one save may add over the last stored record): 30 floors + 300 an hour,
  -- 8 levels + 40 an hour (levels counted above 30 only: early levels come in minutes).
  -- In all since the starting point (cumulative, so that many small saves cannot add up to a jump): 30 floors +
  -- 200 an hour, 8 levels + 30 an hour. Calibrated on the simulators: sim/depth.js, an hour of play with fights at
  -- 2x speed, gives at most ~110 floors an hour (200 leaves room for skipping every fight's playback); sim/simulate.js
  -- needs ~113 raids from a new hero to the Hell clear (level ~83) and ~80 of them from level 30, i.e. at a very fast
  -- 1.5-2 minutes a raid about 2-3 hours from level 30 to 83 (~20 levels an hour, ~15 past level 70). 30 an hour
  -- means level 30 to 83 in no less than 1.5 hours and to 99 in no less than 2 hours: no real player gets there
  -- faster, a script pushing saves does. Real play only ever comes in under these (breaks only add time).
  burst_floors constant int := 30;
  floors_per_hour constant int := 300;
  rate_floors_per_hour constant int := 200;
  burst_levels constant int := 8;
  levels_per_hour constant int := 40;
  rate_levels_per_hour constant int := 30;
  level_check_from constant int := 30;
  -- Checks about the state itself (not growth): an admin's approval covers them while the hero is no further along.
  static_checks constant text[] := array['depth_level', 'depth_locked', 'hell_early', 'first_seen_high', 'dup_hero'];
  sl jsonb;
  h jsonb;
  v_hid text;
  cls text;
  lvl int;
  v_xp numeric;
  hc boolean;
  dead boolean;
  v_deepest int;
  n_done boolean;
  nm_done boolean;
  hell_done boolean;
  hell_wait boolean;
  hname text;
  prev public.lb_entries%rowtype;
  had boolean;
  reasons text[];
  review_level constant int := 90;
  review_deepest constant int := 150;
  notes text[];
  hours_d numeric;
  hours_l numeric;
  hours_r numeric;
  v_count int;
  new_level int;
  new_xp bigint;
  new_deepest int;
  up_level boolean;
  up_deepest boolean;
  hell_new boolean;
  hide boolean;
  r text;
  n int := 0;
begin
  if p_user is null or jsonb_typeof(p_data) is distinct from 'object' or jsonb_typeof(p_data -> 'slots') is distinct from 'array' then
    return;
  end if;
  for sl in select value from jsonb_array_elements(p_data -> 'slots') loop
    n := n + 1;
    exit when n > hero_slots;
    continue when jsonb_typeof(sl) is distinct from 'object' or jsonb_typeof(sl -> 'hero') is distinct from 'object';
    h := sl -> 'hero';
    v_hid := h ->> 'id';
    cls := h ->> 'classId';
    continue when jsonb_typeof(h -> 'id') is distinct from 'string' or v_hid !~ '^[A-Za-z0-9_-]{1,40}$';
    continue when cls is null or not (cls = any (classes));
    continue when jsonb_typeof(h -> 'level') is distinct from 'number';
    reasons := array[]::text[];
    notes := array[]::text[];
    hours_d := null; hours_l := null; hours_r := null;
    -- Level and experience (inside the level, as the game keeps it).
    if (h ->> 'level')::numeric <> trunc((h ->> 'level')::numeric) or (h ->> 'level')::numeric < 1 or (h ->> 'level')::numeric > 99 then
      reasons := array_append(reasons, 'level_range'::text);
      lvl := least(99, greatest(1, trunc((h ->> 'level')::numeric)))::int;
    else
      lvl := (h ->> 'level')::int;
    end if;
    v_xp := case when jsonb_typeof(h -> 'xp') = 'number' then (h ->> 'xp')::numeric else 0 end;
    if v_xp < 0 or v_xp <> trunc(v_xp) or (lvl < 99 and v_xp > public.lb_to_next(lvl)) or (lvl >= 99 and v_xp > 0) then
      reasons := array_append(reasons, 'xp_level'::text);
      v_xp := least(greatest(trunc(v_xp), 0), public.lb_to_next(least(lvl, 98)));
    end if;
    hc := coalesce(h -> 'hardcore' = 'true'::jsonb, false);
    dead := coalesce(h -> 'dead' = 'true'::jsonb, false);
    -- Progress.
    n_done := coalesce(h -> 'cleared' -> final_zone = 'true'::jsonb, false);
    nm_done := coalesce(h -> 'progress' -> 'nightmare' -> final_zone = 'true'::jsonb, false);
    hell_done := coalesce(h -> 'progress' -> 'hell' -> final_zone = 'true'::jsonb, false);
    if jsonb_typeof(h -> 'depth' -> 'deepest') = 'number' then
      if (h -> 'depth' ->> 'deepest')::numeric < 0 or (h -> 'depth' ->> 'deepest')::numeric > 9999
         or (h -> 'depth' ->> 'deepest')::numeric <> trunc((h -> 'depth' ->> 'deepest')::numeric) then
        reasons := array_append(reasons, 'depth_range'::text);
        v_deepest := least(9999, greatest(0, trunc((h -> 'depth' ->> 'deepest')::numeric)))::int;
      else
        v_deepest := (h -> 'depth' ->> 'deepest')::int;
      end if;
    else
      v_deepest := 0;
    end if;
    if v_deepest > 0 and not n_done then reasons := array_append(reasons, 'depth_locked'::text); end if;
    if v_deepest > public.lb_depth_cap(lvl) then reasons := array_append(reasons, 'depth_level'::text); end if;
    if hell_done and (not nm_done or not n_done or lvl < hell_min_level) then reasons := array_append(reasons, 'hell_early'::text); end if;
    hname := public.lb_clean_hero_name(case when jsonb_typeof(sl -> 'name') = 'string' then sl ->> 'name' else '' end);

    select * into prev from public.lb_entries e where e.user_id = p_user and e.hero_id = v_hid;
    had := found;
    if not had then
      select count(*) into v_count from public.lb_entries e where e.user_id = p_user;
      if v_count >= max_entries then
        notes := array_append(notes, 'hero_cap'::text);  -- noted below, not kept
      else
        perform public.lb_ensure_profile(p_user);
        -- First sight: a hero already far along was played somewhere the server did not see (an old local save).
        if not p_backfill and (lvl > level_check_from or v_deepest > 0 or nm_done or hell_done) then
          reasons := array_append(reasons, 'first_seen_high'::text);
        end if;
        if not p_backfill and exists (select 1 from public.lb_entries o where o.hero_id = v_hid and o.user_id <> p_user) then
          reasons := array_append(reasons, 'dup_hero'::text);
        end if;
      end if;
    elsif prev.fallen then
      -- A fallen hardcore hero keeps its last entry as it was; if the save had been deleted, it comes back as it was.
      if prev.hidden and prev.hidden_reason = 'auto:save_gone' then
        update public.lb_entries e set hidden = false, hidden_reason = null where e.user_id = p_user and e.hero_id = v_hid;
      end if;
      continue;
    else
      if prev.class_id <> cls then reasons := array_append(reasons, 'class_changed'::text); end if;
      if prev.hardcore <> hc then reasons := array_append(reasons, 'mode_changed'::text); end if;
      -- Between two saves: against the last stored record and when it was first seen.
      hours_d := greatest(0, extract(epoch from (p_at - coalesce(prev.deepest_at, prev.first_seen))) / 3600);
      hours_l := greatest(0, extract(epoch from (p_at - prev.level_at)) / 3600);
      if v_deepest - prev.deepest > burst_floors + floors_per_hour * hours_d then reasons := array_append(reasons, 'depth_jump'::text); end if;
      if lvl > level_check_from and lvl - prev.level > burst_levels + levels_per_hour * hours_l then reasons := array_append(reasons, 'level_jump'::text); end if;
      -- In all, since the starting point.
      hours_r := greatest(0, extract(epoch from (p_at - coalesce(prev.rate_from, prev.first_seen))) / 3600);
      if v_deepest - coalesce(prev.rate_deepest, 0) > burst_floors + rate_floors_per_hour * hours_r then reasons := array_append(reasons, 'depth_rate'::text); end if;
      if lvl > level_check_from and lvl - greatest(coalesce(prev.rate_level, 1), level_check_from) > burst_levels + rate_levels_per_hour * hours_r then
        reasons := array_append(reasons, 'level_rate'::text);
      end if;
      -- An admin approved what they saw: the state checks do not hide it again until it is further along than that.
      if prev.admin_ok and lvl <= coalesce(prev.rate_level, prev.level) and v_deepest <= coalesce(prev.rate_deepest, prev.deepest) then
        reasons := array(select x from unnest(reasons) x where not (x = any (static_checks)));
      end if;
    end if;

    -- A Hell clear counts only 2 hours or more after Nightmare was first seen done (legacy heroes: not timed).
    hell_wait := hell_done and not p_backfill and (not had or (prev.hell_clear_at is null and not prev.legacy
                 and (prev.nm_at is null or p_at - prev.nm_at < hell_after_nm)));
    if hell_wait and had then notes := array_append(notes, 'hell_wait'::text); end if;

    -- The very top waits for an admin's look the first time a hero gets there (level 90, floor 150 or a Hell clear):
    -- a patient forger can stay under every rate check, but not slip onto the top of a board unseen.
    -- Only the crossing counts, so an approved hero is not sent back for review on every later save. The Hell clear
    -- counts in the save that stamps it (below: not while it still waits for the 2 hours, and the lb_firsts row is
    -- written later in this same save, so the next save no longer sees it as new). With no stored row (not had) prev's
    -- fields are null: "not had or ..." is true whatever the rest is.
    if not p_backfill and not ('hero_cap' = any (notes))
       and ((lvl >= review_level and (not had or prev.level < review_level))
         or (v_deepest >= review_deepest and (not had or prev.deepest < review_deepest))
         or (hell_done and not hell_wait
             and not exists (select 1 from public.lb_firsts f where f.user_id = p_user and f.hero_id = v_hid and f.kind = 'hell_clear'))) then
      reasons := array_append(reasons, 'review_top'::text);
    end if;

    if not ('hero_cap' = any (notes)) then
      -- Never lower: an older save restored on purpose does not take a record away.
      new_level := case when had then greatest(prev.level, lvl) else lvl end;
      new_xp := case when not had or lvl > prev.level then v_xp::bigint when lvl = prev.level then greatest(prev.xp, v_xp::bigint) else prev.xp end;
      new_deepest := case when had then greatest(prev.deepest, v_deepest) else v_deepest end;
      up_level := not had or new_level > prev.level;
      up_deepest := new_deepest > 0 and (not had or new_deepest > prev.deepest);
      hide := cardinality(reasons) > 0;

      if not had then
        insert into public.lb_entries (user_id, hero_id, pid, hero_name, class_id, hardcore, level, xp, level_at, deepest, deepest_at,
                                       fallen, fallen_at, hidden, hidden_reason, first_seen, updated_at, rate_from, rate_level, rate_deepest, nm_at, legacy)
        values (p_user, v_hid, public.lb_pid(p_user, v_hid), hname, cls, hc, new_level, new_xp, p_at, new_deepest,
                case when new_deepest > 0 then p_at end, hc and dead, case when hc and dead then p_at end,
                hide, case when hide then 'auto:' || reasons[1] end, p_at, p_at, p_at, lvl, v_deepest, case when nm_done then p_at end, p_backfill);
      elsif up_level or up_deepest or new_xp <> prev.xp or hname <> prev.hero_name or (hc and dead) or (hide and not prev.hidden)
            or (nm_done and prev.nm_at is null) or prev.hidden_reason = 'auto:save_gone' then
        update public.lb_entries e
           set hero_name = hname,
               level = new_level,
               xp = new_xp,
               level_at = case when up_level then p_at else e.level_at end,
               deepest = new_deepest,
               deepest_at = case when up_deepest then p_at else e.deepest_at end,
               fallen = e.hardcore and dead,
               fallen_at = case when e.hardcore and dead then p_at end,
               nm_at = coalesce(e.nm_at, case when nm_done then p_at end),
               -- A deleted save's heroes come back with it; any other reason to hide stays (an admin's above all).
               hidden = case when e.hidden_reason = 'auto:save_gone' then hide else e.hidden or hide end,
               hidden_reason = case when hide and (not e.hidden or e.hidden_reason = 'auto:save_gone') then 'auto:' || reasons[1]
                                    when e.hidden_reason = 'auto:save_gone' then null else e.hidden_reason end,
               admin_ok = e.admin_ok and not hide,  -- hidden again: the approval is used up
               updated_at = p_at
         where e.user_id = p_user and e.hero_id = v_hid;
      end if;

      -- The first Hell clear: the server's own time, once (and not before 2 hours after Nightmare).
      hell_new := false;
      if hell_done and not hell_wait then
        insert into public.lb_firsts (user_id, hero_id, kind, at, client_at)
        values (p_user, v_hid, 'hell_clear', p_at, public.lb_iso_time(h -> 'firsts' ->> 'hellClearAt'))
        on conflict do nothing;
        hell_new := found;
        if hell_new then
          update public.lb_entries e set hell_clear_at = p_at where e.user_id = p_user and e.hero_id = v_hid;
        end if;
      end if;

      -- This season: the new records of this month.
      if up_level or up_deepest or hell_new then
        insert into public.lb_season as s (season, user_id, hero_id, deepest, deepest_at, level, level_at, hell_clear_at)
        values (v_season, p_user, v_hid,
                case when up_deepest then new_deepest end, case when up_deepest then p_at end,
                case when up_level then new_level end, case when up_level then p_at end,
                case when hell_new then p_at end)
        on conflict (season, user_id, hero_id) do update
           set deepest = coalesce(excluded.deepest, s.deepest),
               deepest_at = coalesce(excluded.deepest_at, s.deepest_at),
               level = coalesce(excluded.level, s.level),
               level_at = coalesce(excluded.level_at, s.level_at),
               hell_clear_at = coalesce(s.hell_clear_at, excluded.hell_clear_at);
      end if;
    else
      hide := false;
    end if;

    -- What the checks found: one line per reason and hero a day at most (saves come every few seconds), and at most
    -- 20 lines an hour per account (made-up heroes cannot flood the admin's list).
    foreach r in array reasons || notes loop
      if not exists (select 1 from public.lb_flags f where f.user_id = p_user and f.hero_id = v_hid and f.reason = r and f.at > now() - interval '1 day')
         and (select count(*) from public.lb_flags f where f.user_id = p_user and f.at > now() - interval '1 hour') < max_flags_hour then
        insert into public.lb_flags (user_id, hero_id, reason, hid, detail)
        values (p_user, v_hid, r, hide and r = any (reasons),
                jsonb_build_object('level', lvl, 'xp', v_xp, 'deepest', v_deepest, 'prevLevel', prev.level, 'prevDeepest', prev.deepest,
                                   'hoursDeepest', round(coalesce(hours_d, 0), 2), 'hoursLevel', round(coalesce(hours_l, 0), 2), 'hoursRate', round(coalesce(hours_r, 0), 2),
                                   'normal', n_done, 'nightmare', nm_done, 'hell', hell_done, 'class', cls, 'hardcore', hc));
      end if;
    end loop;
  end loop;
end;
$$;
revoke all on function public.lb_ingest(uuid, jsonb, timestamptz, boolean) from public, anon, authenticated;

-- The trigger: a save is never lost because of the leaderboard (and never waits for the hall of fame).
create or replace function public.lb_on_save()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.lb_ingest(new.user_id, new.data, now(), false);
  exception when others then
    begin
      if not exists (select 1 from public.lb_flags f where f.user_id = new.user_id and f.reason = 'ingest_error' and f.at > now() - interval '1 hour') then
        insert into public.lb_flags (user_id, hero_id, reason, detail)
        values (new.user_id, null, 'ingest_error', jsonb_build_object('error', left(sqlerrm, 300), 'state', sqlstate));
      end if;
    exception when others then
      null;
    end;
  end;
  return null;
end;
$$;
revoke all on function public.lb_on_save() from public, anon, authenticated;

drop trigger if exists lb_on_save on public.saves;
create trigger lb_on_save after insert or update of data on public.saves for each row execute function public.lb_on_save();

-- A cloud save deleted (delete_save): its heroes leave the boards, but stay (hidden as 'auto:save_gone'), so the next
-- save brings them back with everything the checks know; entries hidden for another reason keep it.
create or replace function public.lb_on_save_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.lb_entries set hidden = true, hidden_reason = 'auto:save_gone' where user_id = old.user_id and not hidden;
  return null;
end;
$$;
revoke all on function public.lb_on_save_delete() from public, anon, authenticated;
drop trigger if exists lb_on_save_delete on public.saves;
create trigger lb_on_save_delete after delete on public.saves for each row execute function public.lb_on_save_delete();

-- ------------------------------------------------------------------ ranking

-- What a board is made of, as SQL text for lb_board (only these fixed pieces are ever put into a query; nothing a
-- player sends). src: the rows; filt: on the board at all; ord: the order (it matches the indexes above); val/at: the
-- number and time shown; k1/k2: the order as numbers, for counting who is ahead (with at and pid after them).
-- depth: the deepest floor, earlier first on a tie. level: the level, then (all time) more experience, then earlier.
-- hell: the first Hell clear, earliest first. Season boards: the records set in this month (lb_season).
create or replace function public.lb_spec(p_board text, p_scope text,
  out src text, out filt text, out ord text, out val text, out at_ text, out k1 text, out k2 text)
language plpgsql
immutable
set search_path = public
as $$
declare
  t text := case when p_scope = 'all' then 'e' else 's' end;
begin
  src := case when p_scope = 'all' then 'public.lb_entries e'
              else 'public.lb_season s join public.lb_entries e on e.user_id = s.user_id and e.hero_id = s.hero_id and s.season = $3' end;
  if p_board = 'depth' then
    filt := t || '.deepest > 0'; val := t || '.deepest'; at_ := t || '.deepest_at';
    ord := format('%1$s.deepest desc, %1$s.deepest_at, e.pid', t); k1 := format('(-%s.deepest)::numeric', t); k2 := '0::numeric';
  elsif p_board = 'level' then
    filt := case when p_scope = 'all' then 'true' else 's.level is not null' end; val := t || '.level'; at_ := t || '.level_at';
    ord := case when p_scope = 'all' then 'e.level desc, e.xp desc, e.level_at, e.pid' else 's.level desc, s.level_at, e.pid' end;
    k1 := format('(-%s.level)::numeric', t); k2 := case when p_scope = 'all' then '(-e.xp)::numeric' else '0::numeric' end;
  else
    filt := t || '.hell_clear_at is not null'; val := 'null::int'; at_ := t || '.hell_clear_at';
    ord := format('%s.hell_clear_at, e.pid', t); k1 := '0::numeric'; k2 := '0::numeric';
  end if;
end;
$$;
revoke all on function public.lb_spec(text, text) from public, anon, authenticated;

-- Who is on a public board, as SQL text ($1 hardcore, $2 class or null): not hidden, not banned, not an admin, and
-- one row per hero id (a hero copied into several accounts: the copy saved last counts).
create or replace function public.lb_vis()
returns text
language sql
immutable
set search_path = public
as $$
  select 'e.hardcore = $1 and not e.hidden and ($2::text is null or e.class_id = $2::text)'
      || ' and not exists (select 1 from public.lb_bans b where b.user_id = e.user_id)'
      || ' and not exists (select 1 from public.admins a where a.user_id = e.user_id)'
      || ' and not exists (select 1 from public.lb_entries o where o.hero_id = e.hero_id and o.user_id <> e.user_id and not o.hidden'
      || ' and (o.updated_at, o.pid) > (e.updated_at, e.pid))';
$$;
revoke all on function public.lb_vis() from public, anon, authenticated;

-- One page of a board (at most 100 rows, read in index order) and, for a signed-in player, where their own heroes
-- stand on it (their place counted; hidden ones, a banned player's or an admin's without a place, marked).
-- Answers { season, board, scope, hardcore, class, total, offset, rows: [...], me: [...] | null }.
create or replace function public.lb_board(p_board text default 'depth', p_scope text default 'season', p_hardcore boolean default false,
                                           p_class text default null, p_offset int default 0, p_limit int default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_season text := public.lb_season_of(now());
  v_cls text := nullif(p_class, '');
  v_hc boolean := coalesce(p_hardcore, false);
  v_lim int := least(greatest(coalesce(p_limit, 100), 1), 100);
  v_off int := least(greatest(coalesce(p_offset, 0), 0), 100000);
  v_banned boolean := false;
  v_admin boolean := false;
  v_vis text := public.lb_vis();
  sp record;
  v_total bigint;
  v_rows jsonb;
  v_mine jsonb := null;
begin
  if p_board is null or p_board not in ('depth', 'level', 'hell') then raise exception 'bad board'; end if;
  if p_scope is null or p_scope not in ('season', 'all') then raise exception 'bad scope'; end if;
  if v_cls is not null and v_cls not in ('reaver', 'elementalist', 'gravecaller', 'ranger', 'templar') then raise exception 'bad class'; end if;
  select * into sp from public.lb_spec(p_board, p_scope);
  execute format('select count(*) from %s where %s and %s', sp.src, v_vis, sp.filt) into v_total using v_hc, v_cls, v_season;
  execute format($q$
    select coalesce(jsonb_agg(jsonb_build_object(
             'rank', $4 + x.n, 'pid', x.pid, 'hero', x.hero_name, 'class', x.class_id, 'level', x.level, 'value', x.v,
             'at', date_trunc('minute', x.a), 'fallen', x.fallen, 'player', pl.name, 'kind', pl.kind, 'guestNo', pl.guest_no,
             'mine', $6::uuid is not null and x.user_id = $6::uuid) order by x.n), '[]'::jsonb)
      from (select row_number() over () as n, p.*
              from (select e.user_id, e.pid, e.hero_name, e.class_id, e.level, e.fallen, %s as v, %s as a
                      from %s where %s and %s order by %s offset $4 limit $5) p) x
      cross join lateral public.lb_player(x.user_id) pl$q$, sp.val, sp.at_, sp.src, v_vis, sp.filt, sp.ord)
    into v_rows using v_hc, v_cls, v_season, v_off, v_lim, v_me;
  if v_me is not null then
    v_banned := exists (select 1 from public.lb_bans b where b.user_id = v_me);
    v_admin := exists (select 1 from public.admins a where a.user_id = v_me);
    -- The player's own heroes on this board; a visible one's place is 1 + how many visible rows come before it.
    execute format($q$
      select coalesce(jsonb_agg(jsonb_build_object(
               'rank', m.rk, 'pid', m.pid, 'hero', m.hero_name, 'class', m.class_id, 'level', m.level, 'value', m.v,
               'at', date_trunc('minute', m.a), 'fallen', m.fallen, 'hidden', m.hidden, 'banned', $7, 'admin', $8,
               'player', pl.name, 'kind', pl.kind, 'guestNo', pl.guest_no, 'mine', true) order by m.rk nulls last, m.level desc), '[]'::jsonb)
        from (select q.*, case when q.vis then 1 + (select count(*) from %1$s where %2$s and %3$s and (%4$s, %5$s, %6$s, e.pid) < (q.k1, q.k2, q.a, q.pid)) end as rk
                from (select e.pid, e.hero_name, e.class_id, e.level, e.fallen, e.hidden, %7$s as v, %6$s as a, %4$s as k1, %5$s as k2, (%2$s) as vis
                        from %1$s where e.user_id = $6 and e.hardcore = $1 and ($2::text is null or e.class_id = $2::text) and %3$s) q) m
        cross join lateral public.lb_player($6) pl$q$, sp.src, v_vis, sp.filt, sp.k1, sp.k2, sp.at_, sp.val)
      into v_mine using v_hc, v_cls, v_season, v_off, v_lim, v_me, v_banned, v_admin;
  end if;
  return jsonb_build_object('season', v_season, 'board', p_board, 'scope', p_scope, 'hardcore', v_hc, 'class', v_cls,
                            'total', v_total, 'offset', v_off, 'rows', v_rows, 'me', v_mine);
end;
$$;
revoke all on function public.lb_board(text, text, boolean, text, int, int) from public;
grant execute on function public.lb_board(text, text, boolean, text, int, int) to anon, authenticated;

-- The top 10 of one board of one season, for every hardcore/softcore and class filter ('' = all classes): one pass
-- over that season's rows. Visible entries only, one row per hero id. Internal (the freeze, lb_hall).
create or replace function public.lb_season_top(p_season text, p_board text)
returns table (hardcore boolean, class_filter text, place int, user_id uuid, hero_id text, pid text, hero_name text, class_id text, value int, value_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select e.user_id, e.hero_id, e.pid, e.hero_name, e.class_id, e.hardcore, e.updated_at,
           case p_board when 'depth' then s.deepest when 'level' then s.level end as v,
           case p_board when 'depth' then s.deepest_at when 'level' then s.level_at else s.hell_clear_at end as at
      from public.lb_season s
      join public.lb_entries e on e.user_id = s.user_id and e.hero_id = s.hero_id
     where s.season = p_season
       and not e.hidden
       and not exists (select 1 from public.lb_bans b where b.user_id = e.user_id)
       and not exists (select 1 from public.admins a where a.user_id = e.user_id)
       and case p_board when 'depth' then coalesce(s.deepest, 0) > 0 when 'level' then s.level is not null else s.hell_clear_at is not null end
  ), dd as (
    select distinct on (b.hero_id) b.* from base b order by b.hero_id, b.updated_at desc, b.pid desc
  ), r as (
    select dd.*,
           row_number() over (partition by dd.hardcore order by dd.v desc nulls last, dd.at, dd.pid) as pa,
           row_number() over (partition by dd.hardcore, dd.class_id order by dd.v desc nulls last, dd.at, dd.pid) as pc
      from dd
  )
  select r.hardcore, ''::text, r.pa::int, r.user_id, r.hero_id, r.pid, r.hero_name, r.class_id, r.v, r.at from r where r.pa <= 10
  union all
  select r.hardcore, r.class_id, r.pc::int, r.user_id, r.hero_id, r.pid, r.hero_name, r.class_id, r.v, r.at from r where r.pc <= 10;
$$;
revoke all on function public.lb_season_top(text, text) from public, anon, authenticated;

-- Freezes every finished season that is not frozen yet. Cheap when there is nothing to do (one indexed lookup).
-- p_wait false (lb_hall): if another session is freezing right now, does not wait and answers false (the caller then
-- works the hall out unfrozen); true when everything finished is frozen. Never called by a save.
create or replace function public.lb_freeze_seasons(p_wait boolean default false)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  cur text := public.lb_season_of(now());
  prev text := public.lb_prev_season(now());
  s text;
  b text;
begin
  if exists (select 1 from public.lb_hall_done where season = prev) then
    return true;
  end if;
  if coalesce(p_wait, false) then
    perform pg_advisory_xact_lock(hashtext('cursewake.lb_freeze'));
  elsif not pg_try_advisory_xact_lock(hashtext('cursewake.lb_freeze')) then
    return false;
  end if;
  if exists (select 1 from public.lb_hall_done where season = prev) then
    return true;
  end if;
  for s in (select x.season from (select distinct ls.season from public.lb_season ls where ls.season < cur union select prev) x
            where not exists (select 1 from public.lb_hall_done d where d.season = x.season) order by 1) loop
    foreach b in array array['depth', 'level', 'hell'] loop
      insert into public.lb_hall (season, board, hardcore, class_filter, place, user_id, hero_id, pid, hero_name, class_id, value, value_at)
      select s, b, t.hardcore, t.class_filter, t.place, t.user_id, t.hero_id, t.pid, t.hero_name, t.class_id, t.value, t.value_at
        from public.lb_season_top(s, b) t
      on conflict do nothing;
    end loop;
    insert into public.lb_hall_done (season) values (s) on conflict do nothing;
  end loop;
  return true;
end;
$$;
revoke all on function public.lb_freeze_seasons(boolean) from public, anon, authenticated;

-- The hall of fame of one board: the last 24 finished seasons, top 3 each, numbered when read (an entry hidden or a
-- player banned since drops out and the next one moves up), names as they are now. Freezes what is not frozen yet if
-- it can; if another reader is freezing right now, works the unfrozen seasons out on the spot.
-- Answers { season, board, hardcore, class, seasons: [{ season, rows }] }.
create or replace function public.lb_hall(p_board text default 'depth', p_hardcore boolean default false, p_class text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_cls text := coalesce(nullif(p_class, ''), '');
  v_hc boolean := coalesce(p_hardcore, false);
  v_cur text := public.lb_season_of(now());
  v_done boolean;
  v_out jsonb;
begin
  if p_board is null or p_board not in ('depth', 'level', 'hell') then raise exception 'bad board'; end if;
  if v_cls <> '' and v_cls not in ('reaver', 'elementalist', 'gravecaller', 'ranger', 'templar') then raise exception 'bad class'; end if;
  v_done := public.lb_freeze_seasons(false);
  with src as (
    select h.season, h.place, h.user_id, h.hero_id, h.pid, h.class_id, h.value, h.value_at
      from public.lb_hall h
     where h.board = p_board and h.hardcore = v_hc and h.class_filter = v_cls
    union all
    select ps.season, t.place, t.user_id, t.hero_id, t.pid, t.class_id, t.value, t.value_at
      from (select distinct ls.season from public.lb_season ls
             where not v_done and ls.season < v_cur and not exists (select 1 from public.lb_hall_done d where d.season = ls.season)) ps
      cross join lateral public.lb_season_top(ps.season, p_board) t
     where t.hardcore = v_hc and t.class_filter = v_cls
  ), vis as (
    select src.*, e.hero_name, e.fallen, row_number() over (partition by src.season order by src.place) as rk
      from src
      join public.lb_entries e on e.user_id = src.user_id and e.hero_id = src.hero_id
     where not e.hidden
       and not exists (select 1 from public.lb_bans b where b.user_id = src.user_id)
       and not exists (select 1 from public.admins a where a.user_id = src.user_id)
  ), top as (
    select * from vis where vis.rk <= 3
  ), seasons as (
    select distinct top.season from top order by top.season desc limit 24
  )
  select coalesce(jsonb_agg(jsonb_build_object('season', x.season, 'rows', x.rows) order by x.season desc), '[]'::jsonb)
    into v_out
    from (
      select top.season,
             jsonb_agg(jsonb_build_object('rank', top.rk, 'pid', top.pid, 'hero', top.hero_name, 'class', top.class_id, 'value', top.value,
                                          'at', date_trunc('minute', top.value_at), 'player', pl.name, 'kind', pl.kind, 'guestNo', pl.guest_no,
                                          'mine', v_me is not null and top.user_id = v_me, 'fallen', top.fallen) order by top.rk) as rows
        from top
        cross join lateral public.lb_player(top.user_id) pl
       where top.season in (select seasons.season from seasons)
       group by top.season
    ) x;
  return jsonb_build_object('season', v_cur, 'board', p_board, 'hardcore', v_hc, 'class', nullif(v_cls, ''), 'seasons', v_out);
end;
$$;
revoke all on function public.lb_hall(text, boolean, text) from public;
grant execute on function public.lb_hall(text, boolean, text) to anon, authenticated;

-- ------------------------------------------------------------------ nickname

-- The signed-in player's name on the boards: { nickname, kind, guestNo, hasEntry, admin }. Gives them a guest number
-- if they have none yet. hasEntry: they have a hero on the boards (only then may they set a nickname).
create or replace function public.lb_profile()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  pl record;
begin
  if me is null then raise exception 'not signed in'; end if;
  perform public.lb_ensure_profile(me);
  select * into pl from public.lb_player(me);
  return jsonb_build_object('nickname', case when pl.kind = 'nick' then pl.name end, 'kind', pl.kind,
                            'guestNo', (select p.guest_no from public.lb_profiles p where p.user_id = me),
                            'hasEntry', exists (select 1 from public.lb_entries e where e.user_id = me),
                            'admin', exists (select 1 from public.admins a where a.user_id = me));
end;
$$;
revoke all on function public.lb_profile() from public, anon;
grant execute on function public.lb_profile() to authenticated;

-- Sets (or with an empty text, clears) the public nickname. The same rules as checkNickname in
-- src/client/ranks-core.js: 3-16 characters from lb_name_chars_ok, at least one letter, nothing rude, nothing that
-- poses as a guest, an admin or the game, not the same skeleton (lb_skel) as someone else's; once every 10 seconds;
-- only for a player with a hero on the boards. Answers { ok: true, nickname } or
-- { ok: false, error: 'length' | 'chars' | 'bad_word' | 'reserved' | 'taken' | 'too_often' | 'no_entry' }.
create or replace function public.set_nickname(p_nickname text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  n text := btrim(regexp_replace(coalesce(p_nickname, ''), '\s+', ' ', 'g'));
  sk text;
  v_last timestamptz;
begin
  if me is null then raise exception 'not signed in'; end if;
  perform public.lb_ensure_profile(me);
  select p.nick_at into v_last from public.lb_profiles p where p.user_id = me;
  if v_last is not null and v_last > now() - interval '10 seconds' then
    return jsonb_build_object('ok', false, 'error', 'too_often');
  end if;
  if n = '' then
    update public.lb_profiles set nickname = null, nick_skel = null, nick_at = now(), updated_at = now() where user_id = me;
    return jsonb_build_object('ok', true, 'nickname', null);
  end if;
  if char_length(n) < 3 or char_length(n) > 16 then return jsonb_build_object('ok', false, 'error', 'length'); end if;
  if not public.lb_name_chars_ok(n) or n !~ '[A-Za-záéíóöőúüűÁÉÍÓÖŐÚÜŰ]' then return jsonb_build_object('ok', false, 'error', 'chars'); end if;
  if public.lb_bad_name(n) then return jsonb_build_object('ok', false, 'error', 'bad_word'); end if;
  sk := public.lb_skel(n);
  if sk ~ '(vandor|wanderer|guest|vendeg|admin|moderator|cursewake)' then return jsonb_build_object('ok', false, 'error', 'reserved'); end if;
  -- An admin's names (their nickname, their Discord names) are theirs alone.
  if exists (
    select 1
      from public.admins a
      left join public.lb_profiles ap on ap.user_id = a.user_id
      left join auth.identities i on i.user_id = a.user_id and i.provider = 'discord'
      cross join lateral (values (ap.nickname), (i.identity_data ->> 'full_name'), (i.identity_data ->> 'global_name'),
                                 (i.identity_data -> 'custom_claims' ->> 'global_name'), (i.identity_data ->> 'name'),
                                 (i.identity_data ->> 'user_name'), (i.identity_data ->> 'preferred_username')) v(nm)
     where a.user_id <> me and v.nm is not null and public.lb_skel(regexp_replace(v.nm, '#\d+$', '')) = sk) then
    return jsonb_build_object('ok', false, 'error', 'reserved');
  end if;
  if not exists (select 1 from public.lb_entries e where e.user_id = me) then
    return jsonb_build_object('ok', false, 'error', 'no_entry');
  end if;
  if exists (select 1 from public.lb_profiles p where p.nick_skel = sk and p.nickname is not null and p.user_id <> me) then
    return jsonb_build_object('ok', false, 'error', 'taken');
  end if;
  begin
    update public.lb_profiles set nickname = n, nick_skel = sk, nick_at = now(), updated_at = now() where user_id = me;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'taken');
  end;
  return jsonb_build_object('ok', true, 'nickname', n);
end;
$$;
revoke all on function public.set_nickname(text) from public, anon;
grant execute on function public.set_nickname(text) to authenticated;

-- ------------------------------------------------------------------ admin

-- Entries for the admin: p_filter 'all' | 'hidden' | 'flagged' (has any automatic flag) | 'banned'. The page is
-- picked first (hidden ones first, then the latest changed), then names and flags are read for that page only.
create or replace function public.admin_lb_entries(p_filter text default 'all', p_limit int default 300)
returns table (user_id uuid, hero_id text, pid text, hero_name text, class_id text, hardcore boolean, level int, deepest int,
               hell_clear_at timestamptz, fallen boolean, hidden boolean, hidden_reason text, admin_ok boolean, banned boolean, is_admin boolean,
               player text, name_kind text, guest_no int, flags int, last_flag text, last_flag_at timestamptz, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return query
    with pg as (
      select e.*, exists (select 1 from public.lb_bans b where b.user_id = e.user_id) as is_banned
        from public.lb_entries e
       where case coalesce(p_filter, 'all')
               when 'hidden' then e.hidden
               when 'flagged' then exists (select 1 from public.lb_flags x where x.user_id = e.user_id and x.hero_id = e.hero_id and x.reason not like 'admin%')
               when 'banned' then exists (select 1 from public.lb_bans b where b.user_id = e.user_id)
               else true end
       order by e.hidden desc, e.updated_at desc
       limit least(greatest(coalesce(p_limit, 300), 1), 1000)
    )
    select pg.user_id, pg.hero_id, pg.pid, pg.hero_name, pg.class_id, pg.hardcore, pg.level, pg.deepest, pg.hell_clear_at, pg.fallen,
           pg.hidden, pg.hidden_reason, pg.admin_ok, pg.is_banned, exists (select 1 from public.admins a where a.user_id = pg.user_id),
           pl.name, pl.kind, pl.guest_no, coalesce(f.n, 0)::int, f.reason, f.at, pg.updated_at
      from pg
      left join lateral (
        select count(*) over () as n, x.reason, x.at
          from public.lb_flags x
         where x.user_id = pg.user_id and x.hero_id = pg.hero_id and x.reason not like 'admin%'
         order by x.at desc
         limit 1
      ) f on true
      cross join lateral public.lb_player(pg.user_id) pl
     order by pg.hidden desc, pg.updated_at desc;
end;
$$;
revoke all on function public.admin_lb_entries(text, int) from public, anon;
grant execute on function public.admin_lb_entries(text, int) to authenticated;

-- What the checks found (and what admins did), newest first.
create or replace function public.admin_lb_flags(p_limit int default 200)
returns table (id bigint, at timestamptz, user_id uuid, hero_id text, reason text, hid boolean, detail jsonb, player text, name_kind text, guest_no int, hero_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return query
    with pg as (select * from public.lb_flags f order by f.id desc limit least(greatest(coalesce(p_limit, 200), 1), 1000))
    select pg.id, pg.at, pg.user_id, pg.hero_id, pg.reason, pg.hid, pg.detail, pl.name, pl.kind, pl.guest_no, e.hero_name
      from pg
      left join public.lb_entries e on e.user_id = pg.user_id and e.hero_id = pg.hero_id
      cross join lateral public.lb_player(pg.user_id) pl
     order by pg.id desc;
end;
$$;
revoke all on function public.admin_lb_flags(int) from public, anon;
grant execute on function public.admin_lb_flags(int) to authenticated;

-- Hides an entry, or shows it again. Showing it is an approval of what the admin sees now: it becomes the new starting
-- point of the growth checks, and the state checks do not hide it again until the hero is further along. Anything
-- implausible after that hides it again (the approval is used up).
create or replace function public.admin_lb_hide(p_user uuid, p_hero text, p_hidden boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  hide boolean := coalesce(p_hidden, true);
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.lb_entries e
     set hidden = hide,
         hidden_reason = case when hide then 'admin' end,
         admin_ok = not hide,
         rate_from = case when hide then e.rate_from else now() end,
         rate_level = case when hide then e.rate_level else e.level end,
         rate_deepest = case when hide then e.rate_deepest else e.deepest end
   where e.user_id = p_user and e.hero_id = p_hero;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  insert into public.lb_flags (user_id, hero_id, reason, hid, detail)
  values (p_user, p_hero, case when hide then 'admin_hide' else 'admin_show' end, hide, jsonb_build_object('by', auth.uid()));
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_lb_hide(uuid, text, boolean) from public, anon;
grant execute on function public.admin_lb_hide(uuid, text, boolean) to authenticated;

-- Keeps a player off every board (p_banned true, with a reason), or lets them back (false).
create or replace function public.admin_lb_ban(p_user uuid, p_banned boolean, p_reason text default '')
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  why text := btrim(left(coalesce(p_reason, ''), 200));
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if p_user is null or not exists (select 1 from auth.users u where u.id = p_user) then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if coalesce(p_banned, true) then
    if why = '' then return jsonb_build_object('ok', false, 'error', 'reason'); end if;
    insert into public.lb_bans (user_id, reason, by_user) values (p_user, why, auth.uid())
    on conflict (user_id) do update set reason = excluded.reason, at = now(), by_user = excluded.by_user;
  else
    delete from public.lb_bans where user_id = p_user;
  end if;
  insert into public.lb_flags (user_id, hero_id, reason, hid, detail)
  values (p_user, null, case when coalesce(p_banned, true) then 'admin_ban' else 'admin_unban' end, coalesce(p_banned, true),
          jsonb_build_object('by', auth.uid(), 'note', why));
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_lb_ban(uuid, boolean, text) from public, anon;
grant execute on function public.admin_lb_ban(uuid, boolean, text) to authenticated;

-- ------------------------------------------------------------------ backfill (once; skipped for heroes already there)

-- Every save already in the cloud is read once, with its own time, so the boards are not empty on the first day.
-- These heroes are "legacy" (no first-sight or Hell-timing checks: they were played before the boards existed).
-- Heroes already read are left as they are (a second run of this file changes nothing). The season they count for
-- is the current one; a Hell clear found here is stamped with the save's time (the earliest the server knew of it).
do $$
declare
  s record;
begin
  for s in select sv.user_id, sv.data, sv.updated_at from public.saves sv
            where not exists (select 1 from public.lb_entries e where e.user_id = sv.user_id) loop
    begin
      perform public.lb_ingest(s.user_id, s.data, s.updated_at, true);
    exception when others then
      raise notice 'leaderboard backfill skipped a save: %', sqlerrm;
    end;
  end loop;
  -- Everyone on the boards has a guest number (entries made by an earlier version of this file, too).
  for s in select distinct e.user_id from public.lb_entries e
            where not exists (select 1 from public.lb_profiles p where p.user_id = e.user_id and p.guest_no is not null) loop
    perform public.lb_ensure_profile(s.user_id);
  end loop;
end;
$$;

commit;


-- Tidiness: Supabase's default grants leave table rights the API cannot use anyway.
revoke truncate, references, trigger on public.admins, public.events from authenticated, anon;
