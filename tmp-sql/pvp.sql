-- Cursewake Arena ("Aréna"): asynchronous PvP against other players' saved heroes, with an Elo rating per hero and
-- monthly seasons.
-- Apply by hand in the Supabase SQL editor, AFTER schema.sql, admin.sql, events-limit.sql and leaderboard.sql
-- (it uses their tables and functions: saves, content_max, admins, lb_entries, lb_bans, lb_flags, lb_player,
-- lb_clean_hero_name, lb_season_of, lb_prev_season).
-- Safe to run more than once: tables and indexes "if not exists", functions "create or replace" (or dropped first).
--
-- How it works (the long version is in README.md, "Aréna"):
-- - Nothing a player sends is a hero or a result. The fighters are snapshots the SERVER takes from the players'
--   accepted cloud saves (pvp_snapshot, built from a fixed list of fields) at the moment of the fight; the opponents
--   are offered by the server (pvp_home: five heroes of a similar rating and level, of the same kind - hardcore or
--   not); the seed is made here.
-- - A fight runs in the edge function pvp-fight (server/functions/pvp-fight: the game's own engine, in Deno), which
--   calls pvp_begin (checks everything, takes both snapshots, makes the seed, records a pending match) and then
--   pvp_finish (writes the result, the fight's log and both ratings in one transaction) or pvp_void (the engine could
--   not fight it). All three are callable by the service role only. The browser only asks for a fight and plays back
--   the log it gets.
-- - Limits (the same numbers as B.pvp in src/content/balance.js; a test keeps them equal): 10 fights a day per player
--   (Hungarian day; a fight refused because of the attacker's own save counts too), one every 5 seconds, the same
--   opponent hero at most twice a day, one account against another at most 4 times in 7 days, a hero is fought at most
--   20 times a day; heroes from level 15, opponents at most 10 levels away. Not in the Arena: a fallen hardcore hero,
--   one hidden on the leaderboard (under review), a banned player (leaderboard ban or arena ban) and an admin. Not
--   offered as an opponent: a guest account younger than a day, a hero whose save this engine cannot read, and for a
--   day a hero whose save made a fight fail or that was missing from its own save (and then not in that season's hall
--   of fame either, until an admin clears it: fault_at), a hero first seen less than a day ago. PvP never kills, never costs anything: only the rating moves.
-- - Ratings: Elo, K 24 for both sides (no drift), a hero's first 10 fights of a season 1.5x; never under 100. Two
--   accounts that met in the last 7 days: K halved; one account wins at most 40 points from another in 7 days. The
--   formula is eloChange in src/engine/pvp.js (tested against pvp_elo).
-- - Seasons: calendar months in Hungarian time (as the leaderboard's). A hero's season rating starts at 1000 the first
--   time it fights or is fought in a month (pvp_season_ratings has a row per season); its best rating ever and its
--   all-time record stay (pvp_ratings). The top 10 of every finished season are frozen into the hall of fame once
--   (pvp_hall), lazily, by the first reader of the hall in a new month (no scheduled job).
-- - Anyone may read the Arena board (pvp_board: season / all time) and hall (pvp_hall); a player reads their own
--   fights (pvp_home, pvp_match). No user id ever leaves: heroes are known by the leaderboard's opaque pid.
-- - Admins see the fights (admin_pvp_matches, admin_pvp_match: with seed and snapshots, to replay them), reset a
--   hero's rating (admin_pvp_reset), keep a player out of the Arena (admin_pvp_ban), see the heroes kept out of the
--   hall of fame (admin_pvp_faults) and clear that (admin_pvp_clear_fault). Their actions go to lb_flags.

begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------------ old versions out of the way
drop function if exists public.pvp_begin(uuid, text, text);
drop function if exists public.pvp_finish(uuid, text, numeric, text, int, int, boolean);
drop function if exists public.admin_pvp_matches(int);
drop function if exists public.pvp_void(uuid, text, text);
drop function if exists public.pvp_elo(int, int, text, int, int);
drop function if exists public.pvp_board(boolean, text, int, int);

-- ------------------------------------------------------------------ tables

-- One row per hero that has fought or been fought: its all-time record and best rating. rating: its latest season
-- rating (as it was after its last fight). The hero's name, class and level are read from lb_entries.
create table if not exists public.pvp_ratings (
  user_id uuid not null references auth.users (id) on delete cascade,
  hero_id text not null check (hero_id ~ '^[A-Za-z0-9_-]{1,40}$'),
  hardcore boolean not null,
  rating int not null default 1000,
  wins int not null default 0,
  losses int not null default 0,
  fights int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, hero_id)
);
alter table public.pvp_ratings add column if not exists best_rating int;
alter table public.pvp_ratings add column if not exists best_at timestamptz;
alter table public.pvp_ratings add column if not exists best_season text;
drop index if exists public.pvp_ratings_board_idx;
create index if not exists pvp_ratings_best_idx on public.pvp_ratings (hardcore, best_rating desc, wins desc) where fights > 0;

-- A hero's rating in one season (calendar month, Hungarian time). No row: 1000 and no fights (made when needed).
create table if not exists public.pvp_season_ratings (
  season text not null check (season ~ '^\d{4}-\d{2}$'),
  user_id uuid not null references auth.users (id) on delete cascade,
  hero_id text not null check (hero_id ~ '^[A-Za-z0-9_-]{1,40}$'),
  hardcore boolean not null,
  rating int not null default 1000,
  wins int not null default 0,
  losses int not null default 0,
  fights int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (season, user_id, hero_id)
);
-- fault_at: when the hero was made unattackable by its own player while on the board this season (its save no longer
-- has it in the first 3 slots, or the snapshot cannot be taken): it stays out of this season's hall of fame until an
-- admin clears it (admin_pvp_clear_fault).
alter table public.pvp_season_ratings add column if not exists fault_at timestamptz;
create index if not exists pvp_season_board_idx on public.pvp_season_ratings (season, hardcore, rating desc, wins desc) where fights > 0;
create index if not exists pvp_season_hero_idx on public.pvp_season_ratings (user_id, hero_id, season desc);

-- Every fight. The snapshots and the seed are kept, so a fight can be fought again and checked (admin_pvp_match), and
-- so is its log (log: { units, events }, as the edge function sent it to the attacker), so it can be watched again
-- exactly as it went, whatever the rules are now.
create table if not exists public.pvp_matches (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'pending' check (status in ('pending', 'done', 'void')),
  attacker_user uuid not null references auth.users (id) on delete cascade,
  attacker_hero text not null,
  defender_user uuid not null references auth.users (id) on delete cascade,
  defender_hero text not null,
  hardcore boolean not null,
  seed bigint not null check (seed between 0 and 4294967295),
  attacker_snap jsonb not null,
  defender_snap jsonb not null,
  outcome text check (outcome in ('win', 'loss')),     -- for the attacker
  timeout boolean not null default false,
  rounds numeric,
  log_hash text,
  engine_version int,                                  -- CONTENT_VERSION of the engine that fought it
  rules_version int,                                   -- B.pvp.rulesVersion of the engine that fought it
  att_before int, att_after int, def_before int, def_after int
);
alter table public.pvp_matches add column if not exists void_reason text;
alter table public.pvp_matches add column if not exists void_fault text;          -- 'attacker' / 'defender' / null
alter table public.pvp_matches add column if not exists log jsonb;
alter table public.pvp_matches add column if not exists season text;
alter table public.pvp_matches add column if not exists flags text[] not null default '{}';
alter table public.pvp_matches add column if not exists repeat_pair boolean not null default false;
alter table public.pvp_matches add column if not exists capped boolean not null default false;
create index if not exists pvp_matches_att_idx on public.pvp_matches (attacker_user, created_at desc);
create index if not exists pvp_matches_atth_idx on public.pvp_matches (attacker_user, attacker_hero, created_at desc);
create index if not exists pvp_matches_def_idx on public.pvp_matches (defender_user, defender_hero, created_at desc);
create index if not exists pvp_matches_defu_idx on public.pvp_matches (defender_user, created_at desc);
create index if not exists pvp_matches_at_idx on public.pvp_matches (created_at desc);
-- The tidy-up looks for fights the edge function never finished.
create index if not exists pvp_matches_pending_idx on public.pvp_matches (created_at) where status = 'pending';

-- The opponents last offered to a hero (refs: [{ u, h, p }]: user, hero, pid). A fight is only allowed against one of
-- them; a finished fight uses the offer up.
create table if not exists public.pvp_offers (
  user_id uuid not null references auth.users (id) on delete cascade,
  hero_id text not null,
  made_at timestamptz not null default now(),
  refs jsonb not null default '[]'::jsonb,
  primary key (user_id, hero_id)
);

-- Players kept out of the Arena (a leaderboard ban, lb_bans, keeps them out too).
create table if not exists public.pvp_bans (
  user_id uuid primary key references auth.users (id) on delete cascade,
  reason text not null default '',
  at timestamptz not null default now(),
  by_user uuid
);

-- Heroes whose save made a fight fail as the defender (the engine refused it): neither offered nor on the board
-- until `until` (a day), so nobody keeps picking an opponent that cannot be fought.
create table if not exists public.pvp_bench (
  user_id uuid not null references auth.users (id) on delete cascade,
  hero_id text not null,
  until timestamptz not null,
  reason text not null default '',
  primary key (user_id, hero_id)
);

-- The content version of the engine the edge function runs (sent with every pvp_begin): heroes saved by a newer game
-- are not offered (the engine could not read them).
create table if not exists public.pvp_engine (
  id boolean primary key default true check (id),
  version int not null,
  at timestamptz not null default now()
);

-- Hall of fame: the top 10 of every finished season, frozen once. What is shown is worked out when it is read:
-- entries hidden or players banned since drop out, the rest move up, names are current.
create table if not exists public.pvp_hall (
  season text not null,
  hardcore boolean not null,
  class_filter text not null default '',          -- '' = all classes
  place int not null check (place between 1 and 10),
  user_id uuid not null,
  hero_id text not null,
  pid text not null,
  class_id text not null,
  value int not null,
  wins int not null default 0,
  losses int not null default 0,
  primary key (season, hardcore, class_filter, place)
);
create table if not exists public.pvp_hall_done (
  season text primary key,
  frozen_at timestamptz not null default now()
);

-- The level search of the opponent list.
create index if not exists lb_entries_pvp_idx on public.lb_entries (hardcore, level) where not hidden and not fallen;

-- No direct access for players: only the functions below read or write these.
alter table public.pvp_ratings enable row level security;
alter table public.pvp_season_ratings enable row level security;
alter table public.pvp_matches enable row level security;
alter table public.pvp_offers enable row level security;
alter table public.pvp_bans enable row level security;
alter table public.pvp_bench enable row level security;
alter table public.pvp_engine enable row level security;
alter table public.pvp_hall enable row level security;
alter table public.pvp_hall_done enable row level security;
revoke all on public.pvp_ratings, public.pvp_season_ratings, public.pvp_matches, public.pvp_offers, public.pvp_bans, public.pvp_bench,
  public.pvp_engine, public.pvp_hall, public.pvp_hall_done from anon, authenticated;

-- An earlier version had no seasons: its ratings become this month's season (only on the first run, while the season
-- table is still empty), and its ratings the heroes' best so far.
insert into public.pvp_season_ratings (season, user_id, hero_id, hardcore, rating, wins, losses, fights, updated_at)
select public.lb_season_of(now()), r.user_id, r.hero_id, r.hardcore, r.rating, r.wins, r.losses, r.fights, r.updated_at
  from public.pvp_ratings r
 where r.fights > 0 and not exists (select 1 from public.pvp_season_ratings)
on conflict do nothing;
update public.pvp_ratings set best_rating = rating, best_at = updated_at, best_season = public.lb_season_of(updated_at)
 where best_rating is null and fights > 0;

-- ------------------------------------------------------------------ the rules (the same numbers as B.pvp)

-- One place for the numbers (a test reads them and compares them with balance.js).
create or replace function public.pvp_rules()
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'rulesVersion', 2, 'minLevel', 15, 'dailyLimit', 10, 'startRating', 1000, 'minRating', 100,
    'kAttack', 24, 'kDefend', 24, 'provisional', 10, 'provisionalMult', 1.5,
    'perOpponentDay', 2, 'pairWeek', 4, 'repeatKMult', 0.5, 'accountGainWeek', 40,
    'levelWindow', 10, 'levelWeight', 20,
    'defendDay', 20, 'gapSeconds', 5, 'offerMinutes', 30, 'refreshSeconds', 60, 'offerSize', 5,
    'newGuestHours', 24, 'newHeroHours', 24, 'benchHours', 24, 'flagsHour', 5);
$$;

-- Midnight (Hungarian time) that started the day a moment belongs to, and the next one.
create or replace function public.pvp_day_start(p_at timestamptz default now())
returns timestamptz
language sql
stable
set search_path = public
as $$
  select date_trunc('day', p_at at time zone 'Europe/Budapest') at time zone 'Europe/Budapest';
$$;
create or replace function public.pvp_day_end(p_at timestamptz default now())
returns timestamptz
language sql
stable
set search_path = public
as $$
  select (date_trunc('day', p_at at time zone 'Europe/Budapest') + interval '1 day') at time zone 'Europe/Budapest';
$$;
-- The moment the season of p_at ends (midnight starting the next month, Hungarian time).
create or replace function public.pvp_season_end(p_at timestamptz default now())
returns timestamptz
language sql
stable
set search_path = public
as $$
  select (date_trunc('month', p_at at time zone 'Europe/Budapest') + interval '1 month') at time zone 'Europe/Budapest';
$$;

-- The Elo change of one fight: { att, def }. The same as eloChange in src/engine/pvp.js (JS Math.round: floor(x + 0.5)).
-- p_repeat: the two accounts met in the last 7 days already (K times repeatKMult for both).
create or replace function public.pvp_elo(p_att int, p_def int, p_outcome text, p_att_fights int, p_def_fights int, p_repeat boolean default false)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  r jsonb := public.pvp_rules();
  expected float8 := 1 / (1 + power(10::float8, (p_def - p_att)::float8 / 400));
  score float8 := case when p_outcome = 'win' then 1 else 0 end;
  rep float8 := case when coalesce(p_repeat, false) then (r ->> 'repeatKMult')::float8 else 1 end;
  ka float8 := (r ->> 'kAttack')::float8 * case when p_att_fights < (r ->> 'provisional')::int then (r ->> 'provisionalMult')::float8 else 1 end * rep;
  kd float8 := (r ->> 'kDefend')::float8 * case when p_def_fights < (r ->> 'provisional')::int then (r ->> 'provisionalMult')::float8 else 1 end * rep;
  da int := floor(ka * (score - expected) + 0.5)::int;
  dd int := floor(kd * (expected - score) + 0.5)::int;
  lo int := (r ->> 'minRating')::int;
begin
  if p_att + da < lo then da := lo - p_att; end if;
  if p_def + dd < lo then dd := lo - p_def; end if;
  return jsonb_build_object('att', da, 'def', dd);
end;
$$;

-- ------------------------------------------------------------------ heroes

-- An object of numbers only (at most p_max keys, each at most 40 characters), or null: affix rolls, fixed powers,
-- skill levels. Anything else a save might carry there is left behind.
create or replace function public.pvp_nums(p jsonb, p_max int)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case when jsonb_typeof(p) = 'object' then
    coalesce((select jsonb_object_agg(z.k, z.v) from (
      select e.key as k, e.value as v from jsonb_each(p) e
       where jsonb_typeof(e.value) = 'number' and char_length(e.key) <= 40 order by e.key limit p_max) z), '{}'::jsonb) end;
$$;

-- A string of at most p_max characters, or null.
create or replace function public.pvp_str(p jsonb, p_max int)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case when jsonb_typeof(p) = 'string' and char_length(p #>> '{}') <= p_max then p end;
$$;

-- One item as the Arena reads it: only these keys (base, rarity, ilvl, affixes {id, tier, rolls}, sockets, socketed,
-- unique, setPiece, runeword, fixed, tree), each of the right type and size. A save padded with anything else cannot
-- make the snapshot big (and the hero unattackable). The engine checks the values (plausibleItem).
create or replace function public.pvp_item(p jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case when jsonb_typeof(p) = 'object' and jsonb_typeof(p -> 'base') = 'string' then jsonb_strip_nulls(jsonb_build_object(
    'base', public.pvp_str(p -> 'base', 60),
    'rarity', public.pvp_str(p -> 'rarity', 20),
    'ilvl', case when jsonb_typeof(p -> 'ilvl') = 'number' then p -> 'ilvl' end,
    'affixes', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'id', public.pvp_str(a.v -> 'id', 60),
                  'tier', case when jsonb_typeof(a.v -> 'tier') = 'number' then a.v -> 'tier' end,
                  'rolls', public.pvp_nums(a.v -> 'rolls', 8))) order by a.i), '[]'::jsonb)
                  from jsonb_array_elements(case when jsonb_typeof(p -> 'affixes') = 'array' then p -> 'affixes' else '[]'::jsonb end) with ordinality as a(v, i)
                 where a.i <= 6 and jsonb_typeof(a.v) = 'object'),
    'sockets', case when jsonb_typeof(p -> 'sockets') = 'number' then p -> 'sockets' end,
    'socketed', (select coalesce(jsonb_agg(s.v order by s.i), '[]'::jsonb)
                   from jsonb_array_elements(case when jsonb_typeof(p -> 'socketed') = 'array' then p -> 'socketed' else '[]'::jsonb end) with ordinality as s(v, i)
                  where s.i <= 6 and public.pvp_str(s.v, 40) is not null),
    'unique', public.pvp_str(p -> 'unique', 60),
    'setPiece', public.pvp_str(p -> 'setPiece', 60),
    'runeword', public.pvp_str(p -> 'runeword', 60),
    'fixed', public.pvp_nums(p -> 'fixed', 40),
    'tree', public.pvp_str(p -> 'tree', 40))) end;
$$;

-- The worn items of a hero or companion (only the given slots, only items).
create or replace function public.pvp_gear(p jsonb, p_slots text[])
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce((select jsonb_object_agg(sl, public.pvp_item(p -> sl)) from unnest(p_slots) sl
                    where jsonb_typeof(p) = 'object' and public.pvp_item(p -> sl) is not null), '{}'::jsonb);
$$;

-- A hero as the Arena fights it, taken from the player's accepted cloud save (only the first 3 slots, as the
-- leaderboard reads them): what the engine needs to work out its numbers again (class, level, attributes, skills,
-- gear, battle order, targeting, companion), built field by field from a fixed list, and nothing else (no bag, no
-- gold, no chest). null: no such hero. The game's own engine checks it again before a fight (cleanSnapshot in
-- src/engine/pvp.js).
create or replace function public.pvp_snapshot(p_user uuid, p_hero text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d jsonb;
  sl jsonb;
  h jsonb;
  out jsonb;
  n int := 0;
begin
  select s.data into d from public.saves s where s.user_id = p_user;
  if d is null or jsonb_typeof(d -> 'slots') is distinct from 'array' then return null; end if;
  for sl in select value from jsonb_array_elements(d -> 'slots') loop
    n := n + 1;
    exit when n > 3;
    continue when jsonb_typeof(sl) is distinct from 'object' or jsonb_typeof(sl -> 'hero') is distinct from 'object';
    h := sl -> 'hero';
    continue when jsonb_typeof(h -> 'id') is distinct from 'string' or h ->> 'id' <> p_hero;
    out := jsonb_strip_nulls(jsonb_build_object(
      'v', 1,
      'id', h -> 'id',
      'name', public.lb_clean_hero_name(case when jsonb_typeof(sl -> 'name') = 'string' then sl ->> 'name' else '' end),
      'classId', public.pvp_str(h -> 'classId', 20),
      'level', case when jsonb_typeof(h -> 'level') = 'number' then h -> 'level' end,
      'attrs', (select jsonb_object_agg(k, h -> 'attrs' -> k) from unnest(array['str', 'dex', 'vit', 'ene']) k where jsonb_typeof(h -> 'attrs' -> k) = 'number'),
      'skills', public.pvp_nums(h -> 'skills', 80),
      'equipment', public.pvp_gear(h -> 'equipment', array['weapon', 'offhand', 'helm', 'body', 'gloves', 'belt', 'boots', 'amulet', 'ring1', 'ring2']),
      'tactics', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                    'skill', public.pvp_str(t.v -> 'skill', 40),
                    'cond', case when jsonb_typeof(t.v -> 'cond') = 'object' then jsonb_strip_nulls(jsonb_build_object(
                              'type', public.pvp_str(t.v -> 'cond' -> 'type', 20),
                              'value', case when jsonb_typeof(t.v -> 'cond' -> 'value') = 'number' then t.v -> 'cond' -> 'value' end)) end)) order by t.i), '[]'::jsonb)
                    from jsonb_array_elements(case when jsonb_typeof(h -> 'tactics') = 'array' then h -> 'tactics' else '[]'::jsonb end) with ordinality as t(v, i)
                   where t.i <= 4 and jsonb_typeof(t.v) = 'object'),
      'targeting', public.pvp_str(h -> 'targeting', 20),
      'potionThreshold', case when jsonb_typeof(h -> 'potionThreshold') = 'number' then h -> 'potionThreshold' end,
      'merc', case when jsonb_typeof(h -> 'merc') = 'object' then jsonb_build_object('type', public.pvp_str(h -> 'merc' -> 'type', 40),
                'equipment', public.pvp_gear(h -> 'merc' -> 'equipment', array['weapon', 'offhand', 'helm', 'body'])) end,
      'hardcore', coalesce(h -> 'hardcore' = 'true'::jsonb, false),
      -- Only a hardcore hero dies (a softcore save's dead flag is only how its last run ended: it can still be fought).
      'dead', coalesce(h -> 'hardcore' = 'true'::jsonb, false) and coalesce(h -> 'dead' = 'true'::jsonb, false),
      'contentVersion', case when jsonb_typeof(d -> 'contentVersion') = 'number' then d -> 'contentVersion' else '0'::jsonb end));
    -- Built from a fixed list of small fields, a real hero is a few kB; this is only a last guard.
    if octet_length(out::text) > 60000 then return null; end if;
    return out;
  end loop;
  return null;
end;
$$;

-- How many of a snapshot's main gear slots are filled (weapon, body, helm, gloves, belt, boots).
create or replace function public.pvp_worn(p_snap jsonb)
returns int
language sql
immutable
set search_path = public
as $$
  select count(*)::int from unnest(array['weapon', 'body', 'helm', 'gloves', 'belt', 'boots']) sl
   where jsonb_typeof(p_snap -> 'equipment' -> sl) = 'object';
$$;

-- Why a hero may not fight (or be fought) now, or null if it may: 'banned', 'admin' (admins test the Arena but do not
-- compete in it, as on the leaderboard), 'not_listed' (not on the leaderboard: not saved to the cloud, or not in the
-- first 3 slots), 'under_review' (hidden on the leaderboard), 'fallen', 'low_level', 'no_save'.
create or replace function public.pvp_reason(p_user uuid, p_hero text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  e public.lb_entries%rowtype;
begin
  if exists (select 1 from public.pvp_bans b where b.user_id = p_user) or exists (select 1 from public.lb_bans b where b.user_id = p_user) then
    return 'banned';
  end if;
  if exists (select 1 from public.admins a where a.user_id = p_user) then return 'admin'; end if;
  select * into e from public.lb_entries x where x.user_id = p_user and x.hero_id = p_hero;
  if not found then return 'not_listed'; end if;
  if e.fallen then return 'fallen'; end if;
  if e.hidden then return case when e.hidden_reason = 'auto:save_gone' then 'no_save' else 'under_review' end; end if;
  if e.level < (public.pvp_rules() ->> 'minLevel')::int then return 'low_level'; end if;
  if not exists (select 1 from public.saves s where s.user_id = p_user) then return 'no_save'; end if;
  return null;
end;
$$;

-- Is a hero kept off the offers and the board for a while (its save made a fight fail)?
create or replace function public.pvp_benched(p_user uuid, p_hero text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.pvp_bench b where b.user_id = p_user and b.hero_id = p_hero and b.until > now());
$$;

-- A note for the admin (lb_flags), at most one of a kind per hero an hour and at most flagsHour 'pvp_' notes per
-- player an hour (a player cannot flood the list).
create or replace function public.pvp_flag(p_user uuid, p_hero text, p_reason text, p_detail jsonb default '{}'::jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.lb_flags f where f.user_id = p_user and f.hero_id is not distinct from p_hero and f.reason = p_reason and f.at > now() - interval '1 hour')
     or (select count(*) from public.lb_flags f where f.user_id = p_user and f.reason like 'pvp\_%' and f.at > now() - interval '1 hour') >= (public.pvp_rules() ->> 'flagsHour')::int then
    return;
  end if;
  insert into public.lb_flags (user_id, hero_id, reason, hid, detail) values (p_user, p_hero, p_reason, false, coalesce(p_detail, '{}'::jsonb));
end;
$$;

-- A hero's rating rows (made the first time they are needed): its all-time row, and its row of the current season
-- (a new season starts it at 1000).
create or replace function public.pvp_ensure_rating(p_user uuid, p_hero text, p_hardcore boolean)
returns void
language sql
volatile
security definer
set search_path = public
as $$
  insert into public.pvp_ratings (user_id, hero_id, hardcore, rating)
  values (p_user, p_hero, p_hardcore, (public.pvp_rules() ->> 'startRating')::int)
  on conflict (user_id, hero_id) do nothing;
  insert into public.pvp_season_ratings (season, user_id, hero_id, hardcore, rating)
  values (public.lb_season_of(now()), p_user, p_hero, p_hardcore, (public.pvp_rules() ->> 'startRating')::int)
  on conflict (season, user_id, hero_id) do nothing;
$$;

-- One opponent / one board row as the game shows it: never a user id. rating, wins, losses: this season's;
-- best: the best rating it ever had.
create or replace function public.pvp_public_hero(p_user uuid, p_hero text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('pid', e.pid, 'hero', e.hero_name, 'class', e.class_id, 'level', e.level,
           'rating', coalesce(s.rating, (public.pvp_rules() ->> 'startRating')::int), 'wins', coalesce(s.wins, 0), 'losses', coalesce(s.losses, 0),
           'best', r.best_rating, 'fallen', e.fallen, 'player', pl.name, 'kind', pl.kind, 'guestNo', pl.guest_no)
    from public.lb_entries e
    left join public.pvp_ratings r on r.user_id = e.user_id and r.hero_id = e.hero_id
    left join public.pvp_season_ratings s on s.season = public.lb_season_of(now()) and s.user_id = e.user_id and s.hero_id = e.hero_id
    cross join lateral public.lb_player(e.user_id) pl
   where e.user_id = p_user and e.hero_id = p_hero;
$$;

-- Fights that count toward a player's day: finished ones, ones under way, and ones refused because of the player's
-- own save (attacker-fault voids). Not: fights the server could not fight for other reasons.
create or replace function public.pvp_today(p_user uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.pvp_matches m
   where m.attacker_user = p_user and m.created_at >= public.pvp_day_start(now())
     and (m.status = 'done' or (m.status = 'pending' and m.created_at > now() - interval '2 minutes')
          or (m.status = 'void' and m.void_fault = 'attacker'));
$$;

revoke all on function public.pvp_rules(), public.pvp_day_start(timestamptz), public.pvp_day_end(timestamptz), public.pvp_season_end(timestamptz),
  public.pvp_elo(int, int, text, int, int, boolean), public.pvp_nums(jsonb, int), public.pvp_str(jsonb, int), public.pvp_item(jsonb),
  public.pvp_gear(jsonb, text[]), public.pvp_snapshot(uuid, text), public.pvp_worn(jsonb), public.pvp_reason(uuid, text),
  public.pvp_benched(uuid, text), public.pvp_flag(uuid, text, text, jsonb), public.pvp_ensure_rating(uuid, text, boolean),
  public.pvp_public_hero(uuid, text), public.pvp_today(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------------ the Arena page

-- Everything the Arena page of one of the player's heroes shows, in one call:
-- { ok, season, seasonEnds, hero: { pid, rating, wins, losses, fights, best, hardcore, level } | null, reason (why it
--   cannot fight, or null), today, limit, resetAt, opponents: [...], refreshIn (seconds until a new list may be asked
--   for), history: [...] }. rating, wins, losses, fights: this season's.
-- The list of opponents is kept (pvp_offers) for 30 minutes or until a fight uses it; p_refresh asks for a new one
-- (at most once a minute). An opponent that cannot be fought any more drops out of the list.
create or replace function public.pvp_home(p_hero text, p_refresh boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  r jsonb := public.pvp_rules();
  v_day timestamptz := public.pvp_day_start(now());
  v_season text := public.lb_season_of(now());
  v_engine int := (select g.version from public.pvp_engine g where g.id);
  v_reason text;
  e public.lb_entries%rowtype;
  rt public.pvp_ratings%rowtype;
  sr public.pvp_season_ratings%rowtype;
  o public.pvp_offers%rowtype;
  v_today int;
  v_refs jsonb;
  v_opp jsonb := '[]'::jsonb;
  v_hist jsonb;
  v_refresh_in int := 0;
  v_rating int;
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_hero is null or p_hero !~ '^[A-Za-z0-9_-]{1,40}$' then raise exception 'bad hero'; end if;
  select * into e from public.lb_entries x where x.user_id = me and x.hero_id = p_hero;
  v_reason := public.pvp_reason(me, p_hero);
  select * into rt from public.pvp_ratings x where x.user_id = me and x.hero_id = p_hero;
  select * into sr from public.pvp_season_ratings x where x.season = v_season and x.user_id = me and x.hero_id = p_hero;
  v_rating := coalesce(sr.rating, (r ->> 'startRating')::int);
  v_today := public.pvp_today(me);

  if v_reason is null then
    select * into o from public.pvp_offers x where x.user_id = me and x.hero_id = p_hero for update;
    if found and o.made_at > now() - make_interval(mins => (r ->> 'offerMinutes')::int)
       and (not coalesce(p_refresh, false) or o.made_at > now() - make_interval(secs => (r ->> 'refreshSeconds')::int)) then
      v_refs := o.refs;
    else
      -- A new list: heroes of the same kind, close in level, close in rating (this season's) and level first (a
      -- little chance mixes it up).
      select coalesce(jsonb_agg(jsonb_build_object('u', c.user_id, 'h', c.hero_id, 'p', c.pid)), '[]'::jsonb) into v_refs
        from (
          select x.user_id, x.hero_id, x.pid
            from public.lb_entries x
            left join public.pvp_season_ratings xr on xr.season = v_season and xr.user_id = x.user_id and xr.hero_id = x.hero_id
           where x.hardcore = e.hardcore and not x.hidden and not x.fallen
             and x.level >= (r ->> 'minLevel')::int and abs(x.level - e.level) <= (r ->> 'levelWindow')::int
             and x.user_id <> me
             -- A hero first seen on the leaderboard less than a day ago is not offered either (a fresh hero on an old
             -- account is as good a throwaway as a fresh guest account).
             and x.first_seen < now() - make_interval(hours => (r ->> 'newHeroHours')::int)
             and not exists (select 1 from public.lb_entries mine where mine.user_id = me and mine.hero_id = x.hero_id)
             and not exists (select 1 from public.lb_bans b where b.user_id = x.user_id)
             and not exists (select 1 from public.pvp_bans b where b.user_id = x.user_id)
             and not exists (select 1 from public.admins a where a.user_id = x.user_id)
             and not exists (select 1 from public.pvp_bench b where b.user_id = x.user_id and b.hero_id = x.hero_id and b.until > now())
             -- A guest account a day old or younger is not offered (a throwaway account to feed another one points).
             and not exists (select 1 from auth.users u where u.id = x.user_id and coalesce(u.is_anonymous, false)
                               and u.created_at > now() - make_interval(hours => (r ->> 'newGuestHours')::int))
             -- Its save must be readable by the engine the edge function runs.
             and exists (select 1 from public.saves s where s.user_id = x.user_id
                           and (v_engine is null or case when jsonb_typeof(s.data -> 'contentVersion') = 'number' then (s.data ->> 'contentVersion')::numeric else 0 end <= v_engine))
             and (select count(*) from public.pvp_matches m where m.defender_user = x.user_id and m.defender_hero = x.hero_id
                    and m.created_at >= v_day and m.status <> 'void') < (r ->> 'defendDay')::int
             and (select count(*) from public.pvp_matches m where m.attacker_user = me and m.defender_user = x.user_id and m.defender_hero = x.hero_id
                    and m.created_at >= v_day and m.status <> 'void') < (r ->> 'perOpponentDay')::int
             and (select count(*) from public.pvp_matches m
                   where ((m.attacker_user = me and m.defender_user = x.user_id) or (m.attacker_user = x.user_id and m.defender_user = me))
                     and m.created_at > now() - interval '7 days' and m.status <> 'void') < (r ->> 'pairWeek')::int
           order by abs(coalesce(xr.rating, (r ->> 'startRating')::int) - v_rating) + (r ->> 'levelWeight')::int * abs(x.level - e.level) + random() * 60
           limit (r ->> 'offerSize')::int
        ) c;
      insert into public.pvp_offers (user_id, hero_id, made_at, refs) values (me, p_hero, now(), v_refs)
      on conflict (user_id, hero_id) do update set made_at = excluded.made_at, refs = excluded.refs;
      o.made_at := now();
    end if;
    v_refresh_in := greatest(0, ceil(extract(epoch from (o.made_at + make_interval(secs => (r ->> 'refreshSeconds')::int) - now())))::int);
    select coalesce(jsonb_agg(ph.j order by (ph.j ->> 'rating')::int desc), '[]'::jsonb) into v_opp
      from jsonb_array_elements(v_refs) ref
      cross join lateral (select public.pvp_public_hero((ref.value ->> 'u')::uuid, ref.value ->> 'h') as j) ph
     where ph.j is not null and public.pvp_reason((ref.value ->> 'u')::uuid, ref.value ->> 'h') is null
       and not public.pvp_benched((ref.value ->> 'u')::uuid, ref.value ->> 'h');
  end if;

  -- The hero's last fights, attacked or attacking: from this hero's side.
  select coalesce(jsonb_agg(x.j order by x.at desc), '[]'::jsonb) into v_hist
    from (
      select m.finished_at as at,
             jsonb_build_object(
               'id', m.id, 'at', date_trunc('minute', m.finished_at),
               'role', case when m.attacker_user = me and m.attacker_hero = p_hero then 'attack' else 'defense' end,
               'won', case when m.attacker_user = me and m.attacker_hero = p_hero then m.outcome = 'win' else m.outcome = 'loss' end,
               'delta', case when m.attacker_user = me and m.attacker_hero = p_hero then m.att_after - m.att_before else m.def_after - m.def_before end,
               'rating', case when m.attacker_user = me and m.attacker_hero = p_hero then m.att_after else m.def_after end,
               'timeout', m.timeout,
               'opp', coalesce(
                 case when m.attacker_user = me and m.attacker_hero = p_hero then public.pvp_public_hero(m.defender_user, m.defender_hero)
                      else public.pvp_public_hero(m.attacker_user, m.attacker_hero) end,
                 jsonb_build_object('hero', case when m.attacker_user = me and m.attacker_hero = p_hero then m.defender_snap ->> 'name' else m.attacker_snap ->> 'name' end,
                                    'class', case when m.attacker_user = me and m.attacker_hero = p_hero then m.defender_snap ->> 'classId' else m.attacker_snap ->> 'classId' end))
             ) as j
        from public.pvp_matches m
       where m.status = 'done'
         and ((m.attacker_user = me and m.attacker_hero = p_hero) or (m.defender_user = me and m.defender_hero = p_hero))
       order by m.finished_at desc
       limit 15
    ) x;

  return jsonb_build_object(
    'ok', true,
    'season', v_season, 'seasonEnds', public.pvp_season_end(now()),
    'hero', case when e.user_id is null then null else jsonb_build_object('pid', e.pid, 'rating', v_rating, 'wins', coalesce(sr.wins, 0),
              'losses', coalesce(sr.losses, 0), 'fights', coalesce(sr.fights, 0), 'best', rt.best_rating,
              'hardcore', e.hardcore, 'level', e.level) end,
    'reason', v_reason,
    'today', v_today, 'limit', (r ->> 'dailyLimit')::int, 'resetAt', public.pvp_day_end(now()),
    'opponents', v_opp, 'refreshIn', v_refresh_in, 'history', v_hist);
end;
$$;
revoke all on function public.pvp_home(text, boolean) from public, anon;
grant execute on function public.pvp_home(text, boolean) to authenticated;

-- One of the player's own finished fights, to watch it again: { ok, id, seed, rulesVersion, engineVersion, role,
-- outcome, hash, attacker, defender, log } (the two snapshots and, for fights recorded with one, the fight's own log
-- { units, events } from the attacker's side: the game plays that back; without one it fights it again).
create or replace function public.pvp_match(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  m public.pvp_matches%rowtype;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into m from public.pvp_matches x where x.id = p_id and x.status = 'done' and (x.attacker_user = me or x.defender_user = me);
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'id', m.id, 'seed', m.seed, 'rulesVersion', m.rules_version, 'engineVersion', m.engine_version,
    'role', case when m.attacker_user = me then 'attack' else 'defense' end, 'outcome', m.outcome, 'timeout', m.timeout, 'hash', m.log_hash,
    'attacker', m.attacker_snap, 'defender', m.defender_snap, 'log', m.log,
    'attRating', jsonb_build_object('before', m.att_before, 'after', m.att_after),
    'defRating', jsonb_build_object('before', m.def_before, 'after', m.def_after));
end;
$$;
revoke all on function public.pvp_match(uuid) from public, anon;
grant execute on function public.pvp_match(uuid) to authenticated;

-- The Arena board. p_scope 'season': this month's ratings; 'all': every hero's best rating ever (with its all-time
-- wins and losses). Rows like lb_board's (value: the rating), plus wins and losses; for a signed-in player also their
-- own heroes with their place. Visible: on the leaderboard (not hidden), alive, not banned (either ban), not an
-- admin's, not benched.
create or replace function public.pvp_board(p_hardcore boolean default false, p_class text default null, p_offset int default 0, p_limit int default 100,
                                            p_scope text default 'season')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_hc boolean := coalesce(p_hardcore, false);
  v_cls text := nullif(p_class, '');
  v_scope text := coalesce(p_scope, 'season');
  v_season text := public.lb_season_of(now());
  v_lim int := least(greatest(coalesce(p_limit, 100), 1), 100);
  v_off int := least(greatest(coalesce(p_offset, 0), 0), 100000);
  v_total bigint;
  v_rows jsonb;
  v_mine jsonb := null;
begin
  if v_cls is not null and v_cls not in ('reaver', 'elementalist', 'gravecaller', 'ranger', 'templar') then raise exception 'bad class'; end if;
  if v_scope not in ('season', 'all') then raise exception 'bad scope'; end if;
  with src as (
    select s.user_id, s.hero_id, s.rating as v, s.wins, s.losses from public.pvp_season_ratings s
     where v_scope = 'season' and s.season = v_season and s.fights > 0 and s.hardcore = v_hc
    union all
    select a.user_id, a.hero_id, coalesce(a.best_rating, a.rating), a.wins, a.losses from public.pvp_ratings a
     where v_scope = 'all' and a.fights > 0 and a.hardcore = v_hc
  ), vis as (
    -- Everyone on the board, numbered (one pass; the board is small next to the leaderboard).
    select e.user_id, e.hero_id, e.pid, e.hero_name, e.class_id, e.level, src.v, src.wins, src.losses,
           row_number() over (order by src.v desc, src.wins desc, e.pid) as n
      from src
      join public.lb_entries e on e.user_id = src.user_id and e.hero_id = src.hero_id
     where e.hardcore = v_hc and not e.hidden and not e.fallen
       and (v_cls is null or e.class_id = v_cls)
       and not exists (select 1 from public.lb_bans b where b.user_id = e.user_id)
       and not exists (select 1 from public.pvp_bans b where b.user_id = e.user_id)
       and not exists (select 1 from public.admins a where a.user_id = e.user_id)
       and not exists (select 1 from public.pvp_bench b where b.user_id = e.user_id and b.hero_id = e.hero_id and b.until > now())
  ), mine as (
    select src.*, e.pid, e.hero_name, e.class_id, e.level, e.fallen, e.hidden from src
      join public.lb_entries e on e.user_id = src.user_id and e.hero_id = src.hero_id
     where v_me is not null and src.user_id = v_me and (v_cls is null or e.class_id = v_cls)
  )
  select (select count(*) from vis),
         (select coalesce(jsonb_agg(jsonb_build_object('rank', v.n, 'pid', v.pid, 'hero', v.hero_name, 'class', v.class_id, 'level', v.level,
                   'value', v.v, 'wins', v.wins, 'losses', v.losses, 'fallen', false, 'player', pl.name, 'kind', pl.kind, 'guestNo', pl.guest_no,
                   'mine', v_me is not null and v.user_id = v_me) order by v.n), '[]'::jsonb)
            from (select * from vis order by vis.n offset v_off limit v_lim) v
            cross join lateral public.lb_player(v.user_id) pl),
         case when v_me is null then null else
         (select coalesce(jsonb_agg(jsonb_build_object('rank', vv.n, 'pid', mm.pid, 'hero', mm.hero_name, 'class', mm.class_id, 'level', mm.level,
                   'value', mm.v, 'wins', mm.wins, 'losses', mm.losses, 'fallen', mm.fallen, 'hidden', mm.hidden,
                   'banned', exists (select 1 from public.pvp_bans b where b.user_id = v_me) or exists (select 1 from public.lb_bans b where b.user_id = v_me),
                   'admin', exists (select 1 from public.admins a where a.user_id = v_me),
                   'player', pl.name, 'kind', pl.kind, 'guestNo', pl.guest_no, 'mine', true) order by vv.n nulls last, mm.v desc), '[]'::jsonb)
            from mine mm
            left join vis vv on vv.user_id = mm.user_id and vv.hero_id = mm.hero_id
            cross join lateral public.lb_player(v_me) pl) end
    into v_total, v_rows, v_mine;
  return jsonb_build_object('season', v_season, 'board', 'arena', 'scope', v_scope, 'seasonEnds', public.pvp_season_end(now()),
    'hardcore', v_hc, 'class', v_cls, 'total', v_total, 'offset', v_off, 'rows', v_rows, 'me', v_mine);
end;
$$;
revoke all on function public.pvp_board(boolean, text, int, int, text) from public;
grant execute on function public.pvp_board(boolean, text, int, int, text) to anon, authenticated;

-- ------------------------------------------------------------------ seasons: the hall of fame

-- The top 10 of one finished season, for every hardcore/softcore and class filter ('' = all classes). Internal.
create or replace function public.pvp_season_top(p_season text)
returns table (hardcore boolean, class_filter text, place int, user_id uuid, hero_id text, pid text, class_id text, value int, wins int, losses int)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select s.hardcore, s.user_id, s.hero_id, e.pid, e.class_id, s.rating, s.wins, s.losses
      from public.pvp_season_ratings s
      join public.lb_entries e on e.user_id = s.user_id and e.hero_id = s.hero_id
     where s.season = p_season and s.fights > 0 and not e.hidden
       -- Not a hero its player made unattackable this season, nor one sitting out now (benched).
       and s.fault_at is null
       and not exists (select 1 from public.pvp_bench b where b.user_id = s.user_id and b.hero_id = s.hero_id and b.until > now())
       and not exists (select 1 from public.lb_bans b where b.user_id = s.user_id)
       and not exists (select 1 from public.pvp_bans b where b.user_id = s.user_id)
       and not exists (select 1 from public.admins a where a.user_id = s.user_id)
  ), r as (
    select base.*,
           row_number() over (partition by base.hardcore order by base.rating desc, base.wins desc, base.pid) as pa,
           row_number() over (partition by base.hardcore, base.class_id order by base.rating desc, base.wins desc, base.pid) as pc
      from base
  )
  select r.hardcore, ''::text, r.pa::int, r.user_id, r.hero_id, r.pid, r.class_id, r.rating, r.wins, r.losses from r where r.pa <= 10
  union all
  select r.hardcore, r.class_id, r.pc::int, r.user_id, r.hero_id, r.pid, r.class_id, r.rating, r.wins, r.losses from r where r.pc <= 10;
$$;

-- Freezes every finished season that is not frozen yet (cheap when there is nothing to do). p_wait false: if another
-- session is freezing right now, does not wait and answers false. Season rows older than 13 months are tidied away
-- once they are frozen.
create or replace function public.pvp_freeze_seasons(p_wait boolean default false)
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
begin
  if exists (select 1 from public.pvp_hall_done where season = prev) then return true; end if;
  if coalesce(p_wait, false) then
    perform pg_advisory_xact_lock(hashtext('cursewake.pvp_freeze'));
  elsif not pg_try_advisory_xact_lock(hashtext('cursewake.pvp_freeze')) then
    return false;
  end if;
  if exists (select 1 from public.pvp_hall_done where season = prev) then return true; end if;
  for s in (select x.season from (select distinct sr.season from public.pvp_season_ratings sr where sr.season < cur union select prev) x
            where not exists (select 1 from public.pvp_hall_done d where d.season = x.season) order by 1) loop
    insert into public.pvp_hall (season, hardcore, class_filter, place, user_id, hero_id, pid, class_id, value, wins, losses)
    select s, t.hardcore, t.class_filter, t.place, t.user_id, t.hero_id, t.pid, t.class_id, t.value, t.wins, t.losses
      from public.pvp_season_top(s) t
    on conflict do nothing;
    insert into public.pvp_hall_done (season) values (s) on conflict do nothing;
  end loop;
  delete from public.pvp_season_ratings
   where season < to_char((now() at time zone 'Europe/Budapest') - interval '13 months', 'YYYY-MM')
     and season in (select d.season from public.pvp_hall_done d);
  return true;
end;
$$;
revoke all on function public.pvp_season_top(text), public.pvp_freeze_seasons(boolean) from public, anon, authenticated;

-- The Arena's hall of fame: the last 12 finished seasons, the top 10 each (the game shows the first 3 large), numbered
-- when read (an entry hidden or a player banned since drops out and the next one moves up), names as they are now.
-- Answers { season, board: 'arena', hardcore, class, seasons: [{ season, rows }] } (value: the season's last rating).
create or replace function public.pvp_hall(p_hardcore boolean default false, p_class text default null)
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
  if v_cls <> '' and v_cls not in ('reaver', 'elementalist', 'gravecaller', 'ranger', 'templar') then raise exception 'bad class'; end if;
  v_done := public.pvp_freeze_seasons(false);
  with src as (
    select h.season, h.place, h.user_id, h.hero_id, h.pid, h.class_id, h.value, h.wins, h.losses
      from public.pvp_hall h
     where h.hardcore = v_hc and h.class_filter = v_cls
    union all
    select ps.season, t.place, t.user_id, t.hero_id, t.pid, t.class_id, t.value, t.wins, t.losses
      from (select distinct sr.season from public.pvp_season_ratings sr
             where not v_done and sr.season < v_cur and not exists (select 1 from public.pvp_hall_done d where d.season = sr.season)) ps
      cross join lateral public.pvp_season_top(ps.season) t
     where t.hardcore = v_hc and t.class_filter = v_cls
  ), vis as (
    select src.*, e.hero_name, e.level, e.fallen, row_number() over (partition by src.season order by src.place) as rk
      from src
      join public.lb_entries e on e.user_id = src.user_id and e.hero_id = src.hero_id
     where not e.hidden
       and not exists (select 1 from public.lb_bans b where b.user_id = src.user_id)
       and not exists (select 1 from public.pvp_bans b where b.user_id = src.user_id)
       and not exists (select 1 from public.admins a where a.user_id = src.user_id)
  ), seasons as (
    select distinct vis.season from vis order by vis.season desc limit 12
  )
  select coalesce(jsonb_agg(jsonb_build_object('season', x.season, 'rows', x.rows) order by x.season desc), '[]'::jsonb)
    into v_out
    from (
      select vis.season,
             jsonb_agg(jsonb_build_object('rank', vis.rk, 'pid', vis.pid, 'hero', vis.hero_name, 'class', vis.class_id, 'level', vis.level,
                                          'value', vis.value, 'wins', vis.wins, 'losses', vis.losses, 'player', pl.name, 'kind', pl.kind,
                                          'guestNo', pl.guest_no, 'mine', v_me is not null and vis.user_id = v_me, 'fallen', vis.fallen) order by vis.rk) as rows
        from vis
        cross join lateral public.lb_player(vis.user_id) pl
       where vis.rk <= 10 and vis.season in (select seasons.season from seasons)
       group by vis.season
    ) x;
  return jsonb_build_object('season', v_cur, 'board', 'arena', 'hardcore', v_hc, 'class', nullif(v_cls, ''), 'seasons', v_out);
end;
$$;
revoke all on function public.pvp_hall(boolean, text) from public;
grant execute on function public.pvp_hall(boolean, text) to anon, authenticated;

-- ------------------------------------------------------------------ a fight (the edge function only)

-- Starts a fight of the player's hero p_hero against the offered opponent p_pid. p_engine: the content version of the
-- engine that will fight it (the edge function's CONTENT_VERSION). Checks every limit, takes both snapshots from the
-- saves, makes the seed and records the match as pending (the offer stays until the fight is finished).
-- Answers { ok: true, matchId, seed, attacker: { snap, rating, fights }, defender: { snap, rating, fights, pub } }
-- or { ok: false, error: 'banned' | 'admin' | 'not_listed' | 'under_review' | 'fallen' | 'low_level' | 'no_save' |
-- 'no_offer' | 'not_offered' | 'daily_limit' | 'too_fast' | 'pair_limit' | 'opponent_gone' | 'engine_outdated' }.
create or replace function public.pvp_begin(p_user uuid, p_hero text, p_pid text, p_engine int default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r jsonb := public.pvp_rules();
  v_day timestamptz := public.pvp_day_start(now());
  v_season text := public.lb_season_of(now());
  v_reason text;
  e public.lb_entries%rowtype;
  o public.pvp_offers%rowtype;
  ref jsonb;
  d_user uuid;
  d_hero text;
  a_snap jsonb;
  d_snap jsonb;
  prev_snap jsonb;
  v_flags text[] := '{}';
  ra public.pvp_season_ratings%rowtype;
  rd public.pvp_season_ratings%rowtype;
  v_seed bigint;
  v_id uuid;
  ver numeric;
begin
  if p_user is null or p_hero is null or p_hero !~ '^[A-Za-z0-9_-]{1,40}$' or p_pid is null then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  -- One fight at a time per player: two at once would both pass the limits.
  perform pg_advisory_xact_lock(hashtext('cursewake.pvp:' || p_user::text));
  -- The engine the edge function runs (pvp_home offers nobody it could not read).
  if p_engine is not null then
    insert into public.pvp_engine (id, version, at) values (true, p_engine, now())
    on conflict (id) do update set version = excluded.version, at = excluded.at
    where public.pvp_engine.version is distinct from excluded.version or public.pvp_engine.at < now() - interval '1 hour';
  end if;

  v_reason := public.pvp_reason(p_user, p_hero);
  if v_reason is not null then return jsonb_build_object('ok', false, 'error', v_reason); end if;
  select * into e from public.lb_entries x where x.user_id = p_user and x.hero_id = p_hero;
  select * into o from public.pvp_offers x where x.user_id = p_user and x.hero_id = p_hero for update;
  if not found or o.made_at < now() - make_interval(mins => (r ->> 'offerMinutes')::int) then
    return jsonb_build_object('ok', false, 'error', 'no_offer');
  end if;
  select value into ref from jsonb_array_elements(o.refs) where value ->> 'p' = p_pid limit 1;
  if ref is null then return jsonb_build_object('ok', false, 'error', 'not_offered'); end if;
  d_user := (ref ->> 'u')::uuid;
  d_hero := ref ->> 'h';
  if public.pvp_today(p_user) >= (r ->> 'dailyLimit')::int then
    return jsonb_build_object('ok', false, 'error', 'daily_limit');
  end if;
  if exists (select 1 from public.pvp_matches m where m.attacker_user = p_user and m.created_at > now() - make_interval(secs => (r ->> 'gapSeconds')::int)) then
    return jsonb_build_object('ok', false, 'error', 'too_fast');
  end if;
  -- Tidiness (only for a request that got this far): matches the edge function never finished, fights older than 90
  -- days, benches that ran out.
  update public.pvp_matches set status = 'void', void_reason = 'stale' where status = 'pending' and created_at < now() - interval '10 minutes';
  delete from public.pvp_matches where id in (select id from public.pvp_matches where created_at < now() - interval '90 days' order by created_at limit 100);
  delete from public.pvp_bench where until < now() - interval '1 day';

  if (select count(*) from public.pvp_matches m where m.attacker_user = p_user and m.defender_user = d_user and m.defender_hero = d_hero
        and m.created_at >= v_day and m.status <> 'void') >= (r ->> 'perOpponentDay')::int
     or (select count(*) from public.pvp_matches m
          where ((m.attacker_user = p_user and m.defender_user = d_user) or (m.attacker_user = d_user and m.defender_user = p_user))
            and m.created_at > now() - interval '7 days' and m.status <> 'void') >= (r ->> 'pairWeek')::int then
    return jsonb_build_object('ok', false, 'error', 'pair_limit');
  end if;
  -- The opponent must still be fightable, of the same kind, and not attacked too often today.
  if public.pvp_reason(d_user, d_hero) is not null or public.pvp_benched(d_user, d_hero)
     or not exists (select 1 from public.lb_entries x where x.user_id = d_user and x.hero_id = d_hero and x.hardcore = e.hardcore)
     or (select count(*) from public.pvp_matches m where m.defender_user = d_user and m.defender_hero = d_hero
           and m.created_at >= v_day and m.status <> 'void') >= (r ->> 'defendDay')::int then
    return jsonb_build_object('ok', false, 'error', 'opponent_gone');
  end if;
  a_snap := public.pvp_snapshot(p_user, p_hero);
  if a_snap is null then return jsonb_build_object('ok', false, 'error', 'no_save'); end if;
  if (a_snap ->> 'dead')::boolean then return jsonb_build_object('ok', false, 'error', 'fallen'); end if;
  ver := (a_snap ->> 'contentVersion')::numeric;
  if p_engine is not null and ver > p_engine then return jsonb_build_object('ok', false, 'error', 'engine_outdated'); end if;
  d_snap := public.pvp_snapshot(d_user, d_hero);
  if d_snap is null or (d_snap ->> 'dead')::boolean then
    -- On the board (listed, not fallen) but not in its own save any more: moved out of the first 3 slots, replaced,
    -- or a save the snapshot cannot read. Its player made it unattackable, so it sits out (benched, not offered, not on
    -- the board), this season's hall of fame does not take it (fault_at, until an admin clears it), and the admin gets
    -- a note. A hardcore hero the leaderboard knows as fallen is not offered in the first place (pvp_reason above) and
    -- is never blamed for it. Returned (not raised), so the bench, the rating row and the note stay.
    if exists (select 1 from public.lb_entries x where x.user_id = d_user and x.hero_id = d_hero and not x.fallen) then
      insert into public.pvp_bench (user_id, hero_id, until, reason)
      values (d_user, d_hero, now() + make_interval(hours => (r ->> 'benchHours')::int), 'gone')
      on conflict (user_id, hero_id) do update set until = excluded.until, reason = excluded.reason;
      perform public.pvp_ensure_rating(d_user, d_hero, e.hardcore);
      update public.pvp_season_ratings set fault_at = now() where season = v_season and user_id = d_user and hero_id = d_hero;
      perform public.pvp_flag(d_user, d_hero, 'pvp_gone', jsonb_build_object('attacker', public.lb_pid(p_user, p_hero),
        'why', case when d_snap is null then 'no_snapshot' else 'dead' end));
    end if;
    return jsonb_build_object('ok', false, 'error', 'opponent_gone');
  end if;
  ver := (d_snap ->> 'contentVersion')::numeric;
  if p_engine is not null and ver > p_engine then return jsonb_build_object('ok', false, 'error', 'opponent_gone'); end if;

  -- A defender with its gear taken off (most main slots empty, or much less than in its last fight of the past 30
  -- days) is easy points for a friend: noted for the admin (the fight still happens).
  if public.pvp_worn(d_snap) <= 3 and (d_snap ->> 'level')::numeric >= 30 then v_flags := array_append(v_flags, 'gear_empty'); end if;
  select case when m.defender_user = d_user and m.defender_hero = d_hero then m.defender_snap else m.attacker_snap end into prev_snap
    from public.pvp_matches m
   where m.status = 'done' and m.created_at > now() - interval '30 days'
     and ((m.defender_user = d_user and m.defender_hero = d_hero) or (m.attacker_user = d_user and m.attacker_hero = d_hero))
   order by m.created_at desc limit 1;
  if prev_snap is not null and public.pvp_worn(prev_snap) - public.pvp_worn(d_snap) >= 3 then v_flags := array_append(v_flags, 'gear_drop'); end if;
  if cardinality(v_flags) > 0 then
    perform public.pvp_flag(d_user, d_hero, 'pvp_' || v_flags[1], jsonb_build_object('attacker', public.lb_pid(p_user, p_hero), 'flags', to_jsonb(v_flags)));
  end if;

  perform public.pvp_ensure_rating(p_user, p_hero, e.hardcore);
  perform public.pvp_ensure_rating(d_user, d_hero, e.hardcore);
  select * into ra from public.pvp_season_ratings x where x.season = v_season and x.user_id = p_user and x.hero_id = p_hero;
  select * into rd from public.pvp_season_ratings x where x.season = v_season and x.user_id = d_user and x.hero_id = d_hero;
  v_seed := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
  insert into public.pvp_matches (attacker_user, attacker_hero, defender_user, defender_hero, hardcore, seed, attacker_snap, defender_snap, att_before, def_before, season, flags)
  values (p_user, p_hero, d_user, d_hero, e.hardcore, v_seed, a_snap, d_snap, ra.rating, rd.rating, v_season, v_flags)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'matchId', v_id, 'seed', v_seed,
    'attacker', jsonb_build_object('snap', a_snap, 'rating', ra.rating, 'fights', ra.fights, 'pid', e.pid),
    'defender', jsonb_build_object('snap', d_snap, 'rating', rd.rating, 'fights', rd.fights, 'pub', public.pvp_public_hero(d_user, d_hero)));
end;
$$;
revoke all on function public.pvp_begin(uuid, text, text, int) from public, anon, authenticated;
grant execute on function public.pvp_begin(uuid, text, text, int) to service_role;

-- Writes the result of a pending fight (as the edge function fought it), its log and both ratings, at once; the
-- attacker's offer is used up. The ratings are the current season's. p_log: { units, events } (kept if under 300 kB);
-- p_att_dropped / p_def_dropped: how many worn items the engine had to take off a hero (noted for the admin).
-- Answers { ok: true, outcome, attacker: { before, after, delta }, defender: { before, after, delta } }
-- or { ok: false, error: 'not_pending' }.
create or replace function public.pvp_finish(p_match uuid, p_outcome text, p_rounds numeric, p_hash text, p_engine int, p_rules int, p_timeout boolean default false,
                                             p_log jsonb default null, p_att_dropped int default 0, p_def_dropped int default 0)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r jsonb := public.pvp_rules();
  v_season text := public.lb_season_of(now());
  m public.pvp_matches%rowtype;
  ra public.pvp_season_ratings%rowtype;
  rd public.pvp_season_ratings%rowtype;
  ch jsonb;
  win boolean := p_outcome = 'win';
  v_repeat boolean;
  v_cap int := (r ->> 'accountGainWeek')::int;
  got int;
  da int;
  dd int;
  v_capped boolean := false;
begin
  if p_outcome is null or p_outcome not in ('win', 'loss') then raise exception 'bad outcome'; end if;
  select * into m from public.pvp_matches x where x.id = p_match for update;
  if not found or m.status <> 'pending' then return jsonb_build_object('ok', false, 'error', 'not_pending'); end if;
  -- (A fight begun just before midnight at the month's end counts in the new season.)
  perform public.pvp_ensure_rating(m.attacker_user, m.attacker_hero, m.hardcore);
  perform public.pvp_ensure_rating(m.defender_user, m.defender_hero, m.hardcore);
  -- Both rows locked in a fixed order (two fights finishing at once never wait on each other in a circle).
  if (m.attacker_user::text || m.attacker_hero) < (m.defender_user::text || m.defender_hero) then
    select * into ra from public.pvp_season_ratings x where x.season = v_season and x.user_id = m.attacker_user and x.hero_id = m.attacker_hero for update;
    select * into rd from public.pvp_season_ratings x where x.season = v_season and x.user_id = m.defender_user and x.hero_id = m.defender_hero for update;
  else
    select * into rd from public.pvp_season_ratings x where x.season = v_season and x.user_id = m.defender_user and x.hero_id = m.defender_hero for update;
    select * into ra from public.pvp_season_ratings x where x.season = v_season and x.user_id = m.attacker_user and x.hero_id = m.attacker_hero for update;
  end if;
  -- Win-trading: two accounts that met in the last 7 days move half as much, and one account wins at most
  -- accountGainWeek points from another in 7 days (all their heroes, attacking and defending).
  v_repeat := exists (select 1 from public.pvp_matches x where x.id <> m.id and x.status = 'done' and x.finished_at > now() - interval '7 days'
                        and ((x.attacker_user = m.attacker_user and x.defender_user = m.defender_user) or (x.attacker_user = m.defender_user and x.defender_user = m.attacker_user)));
  ch := public.pvp_elo(ra.rating, rd.rating, p_outcome, ra.fights, rd.fights, v_repeat);
  da := (ch ->> 'att')::int;
  dd := (ch ->> 'def')::int;
  if da > 0 then
    select coalesce(sum(case when x.attacker_user = m.attacker_user then greatest(0, x.att_after - x.att_before) else greatest(0, x.def_after - x.def_before) end), 0) into got
      from public.pvp_matches x
     where x.status = 'done' and x.finished_at > now() - interval '7 days'
       and ((x.attacker_user = m.attacker_user and x.defender_user = m.defender_user) or (x.attacker_user = m.defender_user and x.defender_user = m.attacker_user));
    if da > v_cap - got then da := greatest(0, v_cap - got); v_capped := true; end if;
  end if;
  if dd > 0 then
    select coalesce(sum(case when x.attacker_user = m.defender_user then greatest(0, x.att_after - x.att_before) else greatest(0, x.def_after - x.def_before) end), 0) into got
      from public.pvp_matches x
     where x.status = 'done' and x.finished_at > now() - interval '7 days'
       and ((x.attacker_user = m.attacker_user and x.defender_user = m.defender_user) or (x.attacker_user = m.defender_user and x.defender_user = m.attacker_user));
    if dd > v_cap - got then dd := greatest(0, v_cap - got); v_capped := true; end if;
  end if;
  update public.pvp_season_ratings set rating = rating + da, wins = wins + case when win then 1 else 0 end,
         losses = losses + case when win then 0 else 1 end, fights = fights + 1, updated_at = now()
   where season = v_season and user_id = m.attacker_user and hero_id = m.attacker_hero;
  update public.pvp_season_ratings set rating = rating + dd, wins = wins + case when win then 0 else 1 end,
         losses = losses + case when win then 1 else 0 end, fights = fights + 1, updated_at = now()
   where season = v_season and user_id = m.defender_user and hero_id = m.defender_hero;
  -- The all-time rows: the record, the latest rating and the best one ever.
  update public.pvp_ratings set rating = ra.rating + da, wins = wins + case when win then 1 else 0 end, losses = losses + case when win then 0 else 1 end,
         fights = fights + 1, updated_at = now(),
         best_at = case when best_rating is null or ra.rating + da > best_rating then now() else best_at end,
         best_season = case when best_rating is null or ra.rating + da > best_rating then v_season else best_season end,
         best_rating = greatest(coalesce(best_rating, 0), ra.rating + da)
   where user_id = m.attacker_user and hero_id = m.attacker_hero;
  update public.pvp_ratings set rating = rd.rating + dd, wins = wins + case when win then 0 else 1 end, losses = losses + case when win then 1 else 0 end,
         fights = fights + 1, updated_at = now(),
         best_at = case when best_rating is null or rd.rating + dd > best_rating then now() else best_at end,
         best_season = case when best_rating is null or rd.rating + dd > best_rating then v_season else best_season end,
         best_rating = greatest(coalesce(best_rating, 0), rd.rating + dd)
   where user_id = m.defender_user and hero_id = m.defender_hero;
  update public.pvp_matches set status = 'done', finished_at = now(), outcome = p_outcome, timeout = coalesce(p_timeout, false),
         rounds = p_rounds, log_hash = left(p_hash, 64), engine_version = p_engine, rules_version = p_rules, season = v_season,
         log = case when jsonb_typeof(p_log) = 'object' and octet_length(p_log::text) < 300000 then p_log end,
         repeat_pair = v_repeat, capped = v_capped,
         att_before = ra.rating, att_after = ra.rating + da, def_before = rd.rating, def_after = rd.rating + dd
   where id = p_match;
  delete from public.pvp_offers where user_id = m.attacker_user and hero_id = m.attacker_hero;
  -- Gear the engine had to take off (could not be worn, or could not be made in the game): noted for the admin.
  if coalesce(p_att_dropped, 0) > 0 then perform public.pvp_flag(m.attacker_user, m.attacker_hero, 'pvp_dropped', jsonb_build_object('match', m.id, 'n', p_att_dropped)); end if;
  if coalesce(p_def_dropped, 0) > 0 then perform public.pvp_flag(m.defender_user, m.defender_hero, 'pvp_dropped', jsonb_build_object('match', m.id, 'n', p_def_dropped)); end if;
  return jsonb_build_object('ok', true, 'outcome', p_outcome,
    'attacker', jsonb_build_object('before', ra.rating, 'after', ra.rating + da, 'delta', da),
    'defender', jsonb_build_object('before', rd.rating, 'after', rd.rating + dd, 'delta', dd));
end;
$$;
revoke all on function public.pvp_finish(uuid, text, numeric, text, int, int, boolean, jsonb, int, int) from public, anon, authenticated;
grant execute on function public.pvp_finish(uuid, text, numeric, text, int, int, boolean, jsonb, int, int) to service_role;

-- A pending fight that could not be fought. p_flag says whose save was at fault:
-- 'attacker': the player's own hero (more points than its level gives, a broken save): the fight counts toward the
--   player's day (so trying again and again does not help), and the hero is noted for the admin (lb_flags,
--   'pvp_<reason>', capped);
-- 'defender': the opponent's save: noted, and the opponent is neither offered nor on the board for benchHours;
-- null: nobody's fault (the engine is older than a save, the database failed): it does not count.
-- The offer stays (it is used up by a finished fight). Answers { ok }.
create or replace function public.pvp_void(p_match uuid, p_reason text, p_flag text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  m public.pvp_matches%rowtype;
  why text := left(coalesce(p_reason, ''), 40);
  fault text := case when p_flag in ('attacker', 'defender') then p_flag end;
begin
  update public.pvp_matches set status = 'void', finished_at = now(), void_reason = why, void_fault = fault
   where id = p_match and status = 'pending' returning * into m;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_pending'); end if;
  if fault = 'attacker' then
    perform public.pvp_flag(m.attacker_user, m.attacker_hero, 'pvp_' || why, jsonb_build_object('match', m.id));
  elsif fault = 'defender' then
    perform public.pvp_flag(m.defender_user, m.defender_hero, 'pvp_' || why, jsonb_build_object('match', m.id));
    insert into public.pvp_bench (user_id, hero_id, until, reason)
    values (m.defender_user, m.defender_hero, now() + make_interval(hours => (public.pvp_rules() ->> 'benchHours')::int), why)
    on conflict (user_id, hero_id) do update set until = excluded.until, reason = excluded.reason;
    -- Its own save stopped the fight: out of this season's hall of fame too, until an admin clears it.
    perform public.pvp_ensure_rating(m.defender_user, m.defender_hero, m.hardcore);
    update public.pvp_season_ratings set fault_at = now()
     where season = public.lb_season_of(now()) and user_id = m.defender_user and hero_id = m.defender_hero;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.pvp_void(uuid, text, text) from public, anon, authenticated;
grant execute on function public.pvp_void(uuid, text, text) to service_role;

-- ------------------------------------------------------------------ admin

-- The latest fights (no snapshots; admin_pvp_match has them). attacker_banned / defender_banned: kept out of the Arena
-- (pvp_bans) now; flags: what pvp_begin noted ('gear_empty', 'gear_drop').
create or replace function public.admin_pvp_matches(p_limit int default 200)
returns table (id uuid, created_at timestamptz, status text, outcome text, timeout boolean, rounds numeric, hardcore boolean,
               attacker_user uuid, attacker_hero text, attacker_name text, attacker_class text, attacker_level int, attacker_player text,
               defender_user uuid, defender_hero text, defender_name text, defender_class text, defender_level int, defender_player text,
               att_before int, att_after int, def_before int, def_after int, log_hash text, engine_version int, rules_version int, void_reason text,
               attacker_guest int, defender_guest int, void_fault text, attacker_banned boolean, defender_banned boolean, flags text[],
               repeat_pair boolean, capped boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return query
    with pg as (select * from public.pvp_matches m order by m.created_at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000))
    select pg.id, pg.created_at, pg.status, pg.outcome, pg.timeout, pg.rounds, pg.hardcore,
           pg.attacker_user, pg.attacker_hero, pg.attacker_snap ->> 'name', pg.attacker_snap ->> 'classId',
           case when jsonb_typeof(pg.attacker_snap -> 'level') = 'number' then (pg.attacker_snap ->> 'level')::numeric::int end,
           pa.name, pg.defender_user, pg.defender_hero, pg.defender_snap ->> 'name', pg.defender_snap ->> 'classId',
           case when jsonb_typeof(pg.defender_snap -> 'level') = 'number' then (pg.defender_snap ->> 'level')::numeric::int end,
           pd.name, pg.att_before, pg.att_after, pg.def_before, pg.def_after, pg.log_hash, pg.engine_version, pg.rules_version, pg.void_reason,
           pa.guest_no, pd.guest_no, pg.void_fault,
           exists (select 1 from public.pvp_bans b where b.user_id = pg.attacker_user),
           exists (select 1 from public.pvp_bans b where b.user_id = pg.defender_user),
           pg.flags, pg.repeat_pair, pg.capped
      from pg
      cross join lateral public.lb_player(pg.attacker_user) pa
      cross join lateral public.lb_player(pg.defender_user) pd
     order by pg.created_at desc;
end;
$$;
revoke all on function public.admin_pvp_matches(int) from public, anon;
grant execute on function public.admin_pvp_matches(int) to authenticated;

-- One fight with its seed and both snapshots (the admin window fights it again and compares the fingerprint).
create or replace function public.admin_pvp_match(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.pvp_matches%rowtype;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select * into m from public.pvp_matches x where x.id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'id', m.id, 'status', m.status, 'seed', m.seed, 'rulesVersion', m.rules_version, 'engineVersion', m.engine_version,
    'outcome', m.outcome, 'hash', m.log_hash, 'attacker', m.attacker_snap, 'defender', m.defender_snap, 'hasLog', m.log is not null);
end;
$$;
revoke all on function public.admin_pvp_match(uuid) from public, anon;
grant execute on function public.admin_pvp_match(uuid) to authenticated;

-- A hero's Arena rating back to the start: this season's 1000 and no fights, and its all-time record and best rating
-- cleared. Its past fights stay in the list (and in past halls of fame).
create or replace function public.admin_pvp_reset(p_user uuid, p_hero text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.pvp_ratings set rating = (public.pvp_rules() ->> 'startRating')::int, wins = 0, losses = 0, fights = 0, updated_at = now(),
         best_rating = null, best_at = null, best_season = null
   where user_id = p_user and hero_id = p_hero;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  update public.pvp_season_ratings set rating = (public.pvp_rules() ->> 'startRating')::int, wins = 0, losses = 0, fights = 0, updated_at = now()
   where season = public.lb_season_of(now()) and user_id = p_user and hero_id = p_hero;
  insert into public.lb_flags (user_id, hero_id, reason, hid, detail) values (p_user, p_hero, 'admin_pvp_reset', false, jsonb_build_object('by', auth.uid()));
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_pvp_reset(uuid, text) from public, anon;
grant execute on function public.admin_pvp_reset(uuid, text) to authenticated;

-- The heroes kept out of a hall of fame because their player made them unattackable or their save stopped a fight
-- (pvp_season_ratings.fault_at), in the seasons not frozen yet, newest first; benched_until: sitting out until then.
create or replace function public.admin_pvp_faults(p_limit int default 100)
returns table (user_id uuid, hero_id text, season text, fault_at timestamptz, hero_name text, class_id text, level int, hardcore boolean,
               player text, guest_no int, benched_until timestamptz, bench_reason text, rating int, fights int)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return query
    select s.user_id, s.hero_id, s.season, s.fault_at, e.hero_name, e.class_id, e.level, s.hardcore, pl.name, pl.guest_no,
           b.until, b.reason, s.rating, s.fights
      from public.pvp_season_ratings s
      left join public.lb_entries e on e.user_id = s.user_id and e.hero_id = s.hero_id
      left join public.pvp_bench b on b.user_id = s.user_id and b.hero_id = s.hero_id and b.until > now()
      cross join lateral public.lb_player(s.user_id) pl
     where s.fault_at is not null and not exists (select 1 from public.pvp_hall_done d where d.season = s.season)
     order by s.fault_at desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;
revoke all on function public.admin_pvp_faults(int) from public, anon;
grant execute on function public.admin_pvp_faults(int) to authenticated;

-- Clears a hero's fault (it may go into the hall of fame again) in every season not frozen yet, and lets it out of the
-- bench at once. Answers { ok } or { ok: false, error: 'not_found' } (no fault to clear).
create or replace function public.admin_pvp_clear_fault(p_user uuid, p_hero text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  n int;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.pvp_season_ratings s set fault_at = null
   where s.user_id = p_user and s.hero_id = p_hero and s.fault_at is not null
     and not exists (select 1 from public.pvp_hall_done d where d.season = s.season);
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  delete from public.pvp_bench where user_id = p_user and hero_id = p_hero;
  insert into public.lb_flags (user_id, hero_id, reason, hid, detail) values (p_user, p_hero, 'admin_pvp_clear_fault', false, jsonb_build_object('by', auth.uid()));
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_pvp_clear_fault(uuid, text) from public, anon;
grant execute on function public.admin_pvp_clear_fault(uuid, text) to authenticated;

-- Keeps a player out of the Arena (p_banned true, with a reason), or lets them back (false).
create or replace function public.admin_pvp_ban(p_user uuid, p_banned boolean, p_reason text default '')
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
    insert into public.pvp_bans (user_id, reason, by_user) values (p_user, why, auth.uid())
    on conflict (user_id) do update set reason = excluded.reason, at = now(), by_user = excluded.by_user;
  else
    delete from public.pvp_bans where user_id = p_user;
  end if;
  insert into public.lb_flags (user_id, hero_id, reason, hid, detail)
  values (p_user, null, case when coalesce(p_banned, true) then 'admin_pvp_ban' else 'admin_pvp_unban' end, coalesce(p_banned, true),
          jsonb_build_object('by', auth.uid(), 'note', why));
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_pvp_ban(uuid, boolean, text) from public, anon;
grant execute on function public.admin_pvp_ban(uuid, boolean, text) to authenticated;

commit;
