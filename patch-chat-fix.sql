-- ============================================================
-- DRS NEXORA — 2026-10-07 (rev.2 — after live E2E proof, same day)
-- Patch: fix "تعذر فتح المحادثة — تحقق من الاتصال" + complete the
-- live database to the v5.5.x server contract.
--
-- ROOT CAUSE — VERIFIED LIVE 2026-10-07 with a REAL session
-- (two admin-created probe users, real JWTs, real RPC call):
--   1. get_or_create_direct_chat(p_other) → 42P10
--      "there is no unique or exclusion constraint matching the
--       ON CONFLICT specification".
--      The unique index chats_direct_pair_unique is PARTIAL
--      (where type='direct'), but the INSERT's conflict target was
--      (user_a, user_b) WITHOUT the matching predicate — PostgreSQL
--      cannot infer a partial index from a bare column list.
--      So EVERY direct-chat open failed server-side and the app
--      showed the misleading "تحقق من الاتصال" message.
--      (The same latent bug existed in schema.sql itself — fixed
--      here in both places: conflict target now carries
--      "where type = 'direct'".)
--   2. get_my_chats() → PGRST202: the RPC the app has called since
--      v5.0.0 was NEVER defined in any schema version (that is why
--      "محادثاتي" never loaded from the server).
--   3. presence_heartbeat/get_presence → PGRST202; tables read_marks,
--      presence, push_tokens missing on live.
--   4. Verified HEALTHY on live (no action needed, definitions
--      refreshed idempotently anyway): register_device (4-param
--      signature, 204 OK with a real device row), chats table
--      columns, chat_members + message_receipts FK/unique
--      constraints (FK-violation probe proved the CREATE TABLE
--      completed with its constraints).
--
-- 100% IDEMPOTENT — safe to run multiple times.
-- Run in: Supabase Dashboard → SQL Editor → paste all → Run.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Safety: chats columns the new objects rely on
-- ------------------------------------------------------------
alter table public.chats add column if not exists deleted_at timestamptz;
alter table public.chats add column if not exists last_message_at timestamptz;
alter table public.chats add column if not exists invite_code text;

-- ------------------------------------------------------------
-- 2) THE critical index — canonical direct pair (PARTIAL by design:
--    group chats keep user_a/user_b NULL, so they never collide).
--    The function below now references it WITH the required
--    predicate "where type = 'direct'" — without that predicate
--    PostgreSQL cannot infer a partial index and raises 42P10.
-- ------------------------------------------------------------
create unique index if not exists chats_direct_pair_unique
  on public.chats (user_a, user_b)
  where type = 'direct';

create index if not exists chats_user_a_idx on public.chats (user_a);
create index if not exists chats_user_b_idx on public.chats (user_b);
create index if not exists chat_members_user_idx on public.chat_members (user_id);

-- ------------------------------------------------------------
-- 3) Membership helpers (recreate to be certain they exist)
-- ------------------------------------------------------------
create or replace function public.is_chat_member(p_chat_id uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.chat_members cm
    where cm.chat_id = p_chat_id
      and cm.user_id = p_user
      and cm.left_at is null
  );
$$;

create or replace function public.is_chat_admin(p_chat_id uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.chat_members cm
    where cm.chat_id = p_chat_id
      and cm.user_id = p_user
      and cm.left_at is null
      and cm.role in ('owner', 'admin')
  );
$$;

-- ------------------------------------------------------------
-- 4) Direct chat creation — HEAD version (recreate to be certain
--    the live body matches the app contract: {chat_id: uuid})
-- ------------------------------------------------------------
create or replace function public.get_or_create_direct_chat(p_other uuid)
returns json language plpgsql security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  lo uuid; hi uuid;
  cid uuid;
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if p_other = me then raise exception 'cannot chat with yourself'; end if;

  lo := least(me, p_other);
  hi := greatest(me, p_other);

  insert into public.chats (type, user_a, user_b, created_by)
  values ('direct', lo, hi, lo)
  -- THE FIX (rev.2): the conflict target MUST carry the index
  -- predicate, otherwise the PARTIAL unique index
  -- chats_direct_pair_unique cannot be inferred → 42P10.
  on conflict (user_a, user_b) where type = 'direct'
  do update set updated_at = now()
  returning id into cid;

  if cid is null then
    select id into cid from public.chats
    where type = 'direct' and user_a = lo and user_b = hi limit 1;
  end if;

  -- ensure both member rows exist
  insert into public.chat_members (chat_id, user_id, role)
  values (cid, lo, 'member'), (cid, hi, 'member')
  on conflict (chat_id, user_id) do update set left_at = null;

  return json_build_object('chat_id', cid);
end;
$$;

-- ------------------------------------------------------------
-- 5) *** NEW *** get_my_chats — the app has called this RPC since
--    v5.0.0 but it was never defined in ANY schema version.
--    (That is why "محادثاتي" never loaded from the server.)
--    Row shape matches lib/data/models/models.dart Chat.fromJson.
-- ------------------------------------------------------------
create or replace function public.get_my_chats()
returns json language sql stable security definer set search_path = public
as $$
  select coalesce(json_agg(row), '[]'::json)
  from (
    select
      c.id,
      c.type,
      case when c.type = 'direct' then to_jsonb(p) end as peer,
      c.name,
      c.description,
      c.avatar_path,
      c.created_by,
      c.invite_code,
      my.role as my_role,
      c.created_at,
      c.last_message_at
    from public.chats c
    join public.chat_members my
      on my.chat_id = c.id
     and my.user_id = auth.uid()
     and my.left_at is null
    left join public.chat_members other
      on other.chat_id = c.id
     and c.type = 'direct'
     and other.user_id <> auth.uid()
     and other.left_at is null
    left join public.profiles p on p.id = other.user_id
    where c.deleted_at is null
    order by coalesce(c.last_message_at, c.updated_at, c.created_at) desc
  ) s;
$$;

-- ------------------------------------------------------------
-- 6) read_marks (v5.1) — private per-user read state
-- ------------------------------------------------------------
create table if not exists public.read_marks (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);
alter table public.read_marks enable row level security;

drop policy if exists "read_marks: read own" on public.read_marks;
create policy "read_marks: read own" on public.read_marks
  for select to authenticated
  using (user_id = auth.uid());

revoke insert, update, delete on public.read_marks from anon, authenticated;

-- ------------------------------------------------------------
-- 7) presence (v5.1) — reachable only through the two RPCs below
-- ------------------------------------------------------------
create table if not exists public.presence (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  last_seen_at timestamptz not null default now()
);
alter table public.presence enable row level security;

-- ------------------------------------------------------------
-- 8) push_tokens (v5.2) — FCM routing addresses, own-row RLS
-- ------------------------------------------------------------
create table if not exists public.push_tokens (
  token      text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  platform   text not null default 'android',
  updated_at timestamptz not null default now()
);
create index if not exists idx_push_tokens_user on public.push_tokens (user_id);
alter table public.push_tokens enable row level security;

drop policy if exists push_tokens_all_own on public.push_tokens;
create policy push_tokens_all_own on public.push_tokens
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update, delete on public.push_tokens to authenticated;

-- ------------------------------------------------------------
-- 9) Device registration + OPK lifecycle (v5.0.0, missing live)
--    Without register_device the device never gets a server-side
--    crypto identity and the whole E2E chain stalls.
-- ------------------------------------------------------------
create or replace function public.register_device(
  p_device_id text, p_device_name text, p_platform text, p_bundle jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  insert into public.devices
    (device_id, user_id, device_name, platform,
     identity_key, signing_key, signed_prekey, signed_prekey_sig, signed_prekey_id)
  values (p_device_id, auth.uid(), p_device_name, p_platform,
          p_bundle->>'identity_key', p_bundle->>'signing_key',
          p_bundle->>'signed_prekey', p_bundle->>'signed_prekey_sig',
          (p_bundle->>'signed_prekey_id')::int)
  on conflict (device_id) do update
    set device_name = excluded.device_name,
        platform = excluded.platform,
        identity_key = excluded.identity_key,
        signing_key = excluded.signing_key,
        signed_prekey = excluded.signed_prekey,
        signed_prekey_sig = excluded.signed_prekey_sig,
        signed_prekey_id = excluded.signed_prekey_id,
        last_active_at = now(),
        revoked_at = null;

  -- replace unconsumed one-time prekeys with the fresh batch
  delete from public.one_time_prekeys
  where device_id = p_device_id and consumed_at is null;

  insert into public.one_time_prekeys (device_id, opk_id, public_key)
  select p_device_id,
         (k->>'id')::int,
         k->>'key'
  from jsonb_array_elements(p_bundle->'one_time_prekeys') as k
  on conflict (device_id, opk_id) do nothing;
end;
$$;

create or replace function public.topup_one_time_prekeys(
  p_device_id text, p_one_time_prekeys jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.devices
                 where device_id = p_device_id and user_id = auth.uid()) then
    raise exception 'not your device';
  end if;
  delete from public.one_time_prekeys
  where device_id = p_device_id and consumed_at is null;
  insert into public.one_time_prekeys (device_id, opk_id, public_key)
  select p_device_id, (k->>'id')::int, k->>'key'
  from jsonb_array_elements(p_one_time_prekeys) as k
  on conflict (device_id, opk_id) do nothing;
end;
$$;

create or replace function public.acknowledge_opk_consumed(
  p_device_id text, p_opk_id int)
returns void language sql security definer set search_path = public
as $$
  update public.one_time_prekeys set consumed_at = now()
  where device_id = p_device_id and opk_id = p_opk_id
    and exists (select 1 from public.devices
                where device_id = p_device_id and user_id = auth.uid());
$$;

-- ------------------------------------------------------------
-- 10) Presence RPCs (v5.1)
-- ------------------------------------------------------------
create or replace function public.presence_heartbeat()
returns void language plpgsql security definer
set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if coalesce(
       (select (s.settings->>'show_presence')::boolean
          from public.user_settings s where s.user_id = me),
       true) is false then
    delete from public.presence where user_id = me;
    return;
  end if;
  insert into public.presence (user_id, last_seen_at)
  values (me, now())
  on conflict (user_id) do update set last_seen_at = now();
  delete from public.presence
   where last_seen_at < now() - interval '1 hour';
end;
$$;

create or replace function public.get_presence(p_user_ids uuid[])
returns table (user_id uuid, last_seen_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select p.user_id, p.last_seen_at
  from public.presence p
  where p.user_id = any (p_user_ids)
    and p.user_id <> auth.uid()
    and p.last_seen_at > now() - interval '70 seconds'
    and exists (
      select 1 from public.chat_members mine
      join public.chat_members theirs
        on theirs.chat_id = mine.chat_id
       and theirs.user_id = p.user_id
       and theirs.left_at is null
      where mine.user_id = auth.uid()
        and mine.left_at is null
    )
    and coalesce(
      (select (s.settings->>'show_presence')::boolean
         from public.user_settings s where s.user_id = p.user_id),
      true)
$$;

-- ------------------------------------------------------------
-- 11) Receipts + unread (v5.1 semantics — read_marks based)
-- ------------------------------------------------------------
create or replace function public.mark_messages_delivered(p_chat_id uuid)
returns void language sql security definer set search_path = public
as $$
  insert into public.message_receipts (message_id, user_id, delivered_at)
  select m.id, auth.uid(), now()
  from public.messages m
  where m.chat_id = p_chat_id
    and m.sender_id <> auth.uid()
    and public.is_chat_member(p_chat_id, auth.uid())
  on conflict (message_id, user_id)
  do update set delivered_at = coalesce(message_receipts.delivered_at, now());
$$;

create or replace function public.mark_messages_read(p_chat_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if not public.is_chat_member(p_chat_id, me) then
    return;
  end if;

  -- (1) private read mark — always, so my unread badge stays correct
  insert into public.read_marks (chat_id, user_id, last_read_at)
  values (p_chat_id, me, now())
  on conflict (chat_id, user_id)
  do update set last_read_at = now();

  -- (2) public read receipts — only when my settings allow it
  if coalesce(
       (select (s.settings->>'read_receipts')::boolean
          from public.user_settings s where s.user_id = me),
       true) then
    insert into public.message_receipts (message_id, user_id, delivered_at, read_at)
    select m.id, me, now(), now()
    from public.messages m
    where m.chat_id = p_chat_id
      and m.sender_id <> me
    on conflict (message_id, user_id)
    do update set read_at = now(),
                  delivered_at = coalesce(message_receipts.delivered_at, now());
  end if;
end;
$$;

create or replace function public.get_unread_counts()
returns table (chat_id uuid, unread bigint)
language sql stable security definer set search_path = public
as $$
  select m.chat_id, count(*)::bigint
  from public.messages m
  left join public.read_marks rm
    on rm.chat_id = m.chat_id and rm.user_id = auth.uid()
  where public.is_chat_member(m.chat_id, auth.uid())
    and m.sender_id <> auth.uid()
    and m.deleted_for_all_at is null
    and m.created_at > coalesce(rm.last_read_at, to_timestamp(0))
  group by m.chat_id;
$$;

-- ------------------------------------------------------------
-- 12) Grants — execute for authenticated (defence in depth;
--     functions already grant EXECUTE to PUBLIC by default)
-- ------------------------------------------------------------
grant execute on function
  public.get_or_create_direct_chat(uuid),
  public.get_my_chats(),
  public.is_chat_member(uuid, uuid),
  public.is_chat_admin(uuid, uuid),
  public.register_device(text, text, text, jsonb),
  public.topup_one_time_prekeys(text, jsonb),
  public.acknowledge_opk_consumed(text, int),
  public.presence_heartbeat(),
  public.get_presence(uuid[]),
  public.mark_messages_delivered(uuid),
  public.mark_messages_read(uuid),
  public.get_unread_counts()
to authenticated;

-- ============================================================
-- END OF PATCH — no artificial termination markers required;
-- if this ran without errors, everything is applied.
-- Verify: the app should now open conversations and load
-- "محادثاتي" from the server.
-- ============================================================
