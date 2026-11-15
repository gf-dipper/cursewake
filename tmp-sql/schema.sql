-- Cursewake cloud saves. One row per player (guest or Discord), the whole save as JSON.
-- Safe to run again on a database that already has it (every step checks or replaces what is there).
-- Players write only through save_game / delete_save (security definer): no direct INSERT, UPDATE or DELETE.
create table if not exists public.saves (
  user_id uuid primary key references auth.users (id) on delete cascade,
  data jsonb not null,
  rev bigint not null default 1,
  updated_at timestamptz not null default now(),
  constraint saves_size check (octet_length(data::text) < 400000)
);

-- At most 400 000 bytes of save text (the game checks the same before it sends; see MAX_BYTES in src/client/sync.js).
-- Replaces the earlier, looser size rule. Added NOT VALID first (no long lock), then checked against the rows already there.
alter table public.saves drop constraint if exists saves_size;
alter table public.saves add constraint saves_size check (octet_length(data::text) < 400000) not valid;
alter table public.saves validate constraint saves_size;

alter table public.saves enable row level security;

drop policy if exists "own save: read" on public.saves;
drop policy if exists "own save: insert" on public.saves;
drop policy if exists "own save: update" on public.saves;
drop policy if exists "own save: delete" on public.saves;
create policy "own save: read" on public.saves for select to authenticated using (user_id = (select auth.uid()));

-- A player reads their own row directly, but writes it only through save_game (and removes it only through
-- delete_save): both run as the owner and check who is asking. No direct INSERT/UPDATE/DELETE, so the revision
-- and content-version guards below cannot be stepped around (and the leaderboard trigger sees only checked saves).
revoke all on public.saves from anon;
revoke insert, update, delete, truncate, references, trigger on public.saves from authenticated;
grant select on public.saves to authenticated;

-- The newest game content version this server accepts (CONTENT_VERSION in src/client/version.js). A save written by
-- a newer one is refused: the server's own engine (the Arena's edge function) could not read it, and the hero would
-- sit in the Arena as an opponent nobody can fight. Bump the number below together with CONTENT_VERSION and run this
-- file again at the deploy (before the new game goes live); a test keeps the two equal. It never goes down by itself
-- (greatest): to lower it, update public.content_meta by hand.
create table if not exists public.content_meta (
  id boolean primary key default true check (id),
  max_version int not null
);
insert into public.content_meta (id, max_version) values (true, 2)
on conflict (id) do update set max_version = greatest(public.content_meta.max_version, excluded.max_version);
alter table public.content_meta enable row level security;
revoke all on public.content_meta from anon, authenticated;

create or replace function public.content_max()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select max_version from public.content_meta where id), 0);
$$;
grant execute on function public.content_max() to anon, authenticated;

-- Saves only when nobody else (another device) saved in between: base_rev must be the revision the client last saw.
-- Answers { ok, rev }, or { ok: false, conflict: true, rev } (someone saved in between),
-- or { ok: false, outdated: true, rev } (the stored save was written by a newer version of the game:
-- an older build must never write over it), or { ok: false, invalid: true } (not a save at all),
-- or { ok: false, tooNew: true, max } (written by a newer game than this server accepts yet: content_max()).
create or replace function public.save_game(p_data jsonb, p_base_rev bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  cur bigint;
  cur_ver numeric;
  -- The content version the save was written with (saves from before versions count as 0).
  new_ver numeric := case when jsonb_typeof(p_data -> 'contentVersion') = 'number' then (p_data ->> 'contentVersion')::numeric else 0 end;
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'invalid', true);
  end if;
  if new_ver > public.content_max() then
    return jsonb_build_object('ok', false, 'tooNew', true, 'max', public.content_max());
  end if;
  select rev, case when jsonb_typeof(data -> 'contentVersion') = 'number' then (data ->> 'contentVersion')::numeric else 0 end
    into cur, cur_ver
    from public.saves where user_id = me for update;
  if not found then
    -- The first save. Two first saves at once (two tabs, two devices): the second one finds the row and goes on below.
    insert into public.saves (user_id, data, rev) values (me, p_data, 1) on conflict (user_id) do nothing;
    if found then
      return jsonb_build_object('ok', true, 'rev', 1);
    end if;
    select rev, case when jsonb_typeof(data -> 'contentVersion') = 'number' then (data ->> 'contentVersion')::numeric else 0 end
      into cur, cur_ver
      from public.saves where user_id = me for update;
    if not found then
      raise exception 'save could not be written, try again';
    end if;
  end if;
  if new_ver < cur_ver then
    return jsonb_build_object('ok', false, 'outdated', true, 'rev', cur);
  end if;
  if p_base_rev is distinct from cur then
    return jsonb_build_object('ok', false, 'conflict', true, 'rev', cur);
  end if;
  update public.saves set data = p_data, rev = cur + 1, updated_at = now() where user_id = me;
  return jsonb_build_object('ok', true, 'rev', cur + 1);
end;
$$;

revoke all on function public.save_game(jsonb, bigint) from public, anon;
grant execute on function public.save_game(jsonb, bigint) to authenticated;

-- Removes the signed-in player's own cloud save (the game in the browser keeps its copy). Answers { ok, deleted }.
-- Their leaderboard heroes are hidden, not deleted (server/leaderboard.sql, lb_on_save_delete), so removing a save
-- and uploading it again never wipes an admin's decision or a hero's record.
create or replace function public.delete_save()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  delete from public.saves where user_id = me;
  return jsonb_build_object('ok', true, 'deleted', found);
end;
$$;
revoke all on function public.delete_save() from public, anon;
grant execute on function public.delete_save() to authenticated;

-- Not done here (noted for later): a CAPTCHA on guest sign-up (Supabase Auth settings), and a scheduled cleanup
-- of guest users that never saved or have not been seen for months (needs the service role, e.g. a pg_cron job).
