-- ============================================================
-- GHOST CATCH ONLINE - Supabase schema
-- Supabase の SQL Editor にこのファイルの内容を全部貼り付けて実行してください。
-- ============================================================

-- 拡張機能（gen_random_uuid 用）
create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 1. ルームテーブル
-- ------------------------------------------------------------
create table if not exists rooms (
  id            uuid primary key default gen_random_uuid(),
  code          text unique not null,
  status        text not null default 'waiting',   -- waiting / playing
  player1_id    uuid,
  player2_id    uuid,
  deck          jsonb not null default '[]'::jsonb, -- カードindexのシャッフル列
  deck_pos      int not null default 0,
  current_idx   int,                                -- 現在のカード(CARD_TABLEのindex)
  card_face     text not null default 'back',        -- back / front
  round_locked  boolean not null default false,
  winner        int,                                 -- 1 or 2
  round_token   int not null default 0,
  score_p1      int not null default 0,
  score_p2      int not null default 0,
  revealed_at   timestamptz,
  updated_at    timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. カード定義テーブル（index.html の CARD_TABLE と同じ順番・同じ正解）
--    サーバー側だけで正誤判定するためのマスタ。クライアントを書き換えても
--    ここを参照するのでチート対策にもなる。
-- ------------------------------------------------------------
create table if not exists card_defs (
  idx     int primary key,
  answer  text not null
);

insert into card_defs (idx, answer) values
 (0,'ghost'),(1,'ghost'),(2,'ghost'),(3,'ghost'),(4,'ghost'),(5,'ghost'),(6,'ghost'),
 (7,'sofa'),(8,'sofa'),
 (9,'book'),(10,'book'),
 (11,'bin'),(12,'bin'),
 (13,'book'),(14,'book'),
 (15,'bin'),(16,'bin'),
 (17,'book'),(18,'book'),
 (19,'sofa'),(20,'sofa'),
 (21,'bin'),(22,'bin'),
 (23,'sofa'),(24,'sofa')
on conflict (idx) do nothing;

-- ------------------------------------------------------------
-- 3. Realtime を有効化
-- ------------------------------------------------------------
alter publication supabase_realtime add table rooms;

-- ------------------------------------------------------------
-- 4. RLS（簡易公開ゲームなので read は誰でも可。書き込みは関数経由のみ）
-- ------------------------------------------------------------
alter table rooms enable row level security;
alter table card_defs enable row level security;

drop policy if exists "rooms_select_all" on rooms;
create policy "rooms_select_all" on rooms for select using (true);

drop policy if exists "card_defs_select_all" on card_defs;
create policy "card_defs_select_all" on card_defs for select using (true);

-- rooms への直接 INSERT/UPDATE は許可しない（関数 SECURITY DEFINER 経由のみ）

-- ------------------------------------------------------------
-- 5. 入室 or 新規作成（合言葉方式）
-- ------------------------------------------------------------
create or replace function join_or_create_room(p_code text, p_player_id uuid)
returns rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room rooms;
  v_deck jsonb;
begin
  -- 既存の「待機中」ルームに2人目として参加
  update rooms
  set player2_id = p_player_id, status = 'playing', updated_at = now()
  where code = p_code
    and player2_id is null
    and player1_id is distinct from p_player_id
    and status = 'waiting'
  returning * into v_room;

  if found then
    return v_room;
  end if;

  -- 既に自分が参加済みのルームなら再接続として返す
  select * into v_room from rooms
  where code = p_code and (player1_id = p_player_id or player2_id = p_player_id);
  if found then
    return v_room;
  end if;

  -- 新規ルーム作成（1人目）
  select jsonb_agg(i order by random()) into v_deck from generate_series(0,24) i;

  insert into rooms (code, player1_id, status, deck, deck_pos, current_idx, card_face)
  values (p_code, p_player_id, 'waiting', v_deck, 1, (v_deck->>0)::int, 'back')
  returning * into v_room;

  return v_room;
exception
  when unique_violation then
    select * into v_room from rooms where code = p_code;
    return v_room;
end;
$$;

grant execute on function join_or_create_room(text, uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 6. カードをめくる（最初に呼んだ人だけが成功する）
-- ------------------------------------------------------------
create or replace function reveal_card(p_room_id uuid)
returns rooms
language sql
security definer
set search_path = public
as $$
  update rooms
  set card_face = 'front', revealed_at = now(), updated_at = now()
  where id = p_room_id and card_face = 'back' and status = 'playing'
  returning *;
$$;

grant execute on function reveal_card(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 7. 解答する（サーバー側で厳密に最速判定）
--    1つの UPDATE 文の WHERE 条件に正誤＆ロック状態をすべて含めることで、
--    同時に複数リクエストが来ても Postgres が直列化するため
--    「最初に条件を満たした1件だけ」が確実に成功する。
-- ------------------------------------------------------------
create or replace function submit_guess(p_room_id uuid, p_player_id uuid, p_piece text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room rooms;
  v_player_num int;
  v_answer text;
  v_updated rooms;
begin
  select * into v_room from rooms where id = p_room_id;
  if not found then
    return jsonb_build_object('result','error','message','room_not_found');
  end if;

  if v_room.player1_id = p_player_id then
    v_player_num := 1;
  elsif v_room.player2_id = p_player_id then
    v_player_num := 2;
  else
    return jsonb_build_object('result','error','message','not_a_player');
  end if;

  select answer into v_answer from card_defs where idx = v_room.current_idx;

  update rooms
  set round_locked = true,
      winner = v_player_num,
      score_p1 = score_p1 + (case when v_player_num = 1 then 1 else 0 end),
      score_p2 = score_p2 + (case when v_player_num = 2 then 1 else 0 end),
      updated_at = now()
  where id = p_room_id
    and card_face = 'front'
    and round_locked = false
    and p_piece = v_answer
  returning * into v_updated;

  if found then
    return jsonb_build_object('result','win','player', v_player_num);
  else
    return jsonb_build_object('result','miss');
  end if;
end;
$$;

grant execute on function submit_guess(uuid, uuid, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 8. 次のカードへ進める（ホスト=player1のクライアントだけが呼ぶ想定。
--    round_locked=true の時だけ動くので二重実行されても安全）
-- ------------------------------------------------------------
create or replace function advance_round(p_room_id uuid)
returns rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room rooms;
  v_deck jsonb;
  v_pos int;
  v_idx int;
begin
  select * into v_room from rooms where id = p_room_id;
  if not found or v_room.round_locked = false then
    return v_room;
  end if;

  v_deck := v_room.deck;
  v_pos := v_room.deck_pos;

  if v_pos >= jsonb_array_length(v_deck) then
    select jsonb_agg(i order by random()) into v_deck from generate_series(0,24) i;
    v_pos := 0;
  end if;

  v_idx := (v_deck->>v_pos)::int;

  update rooms
  set deck = v_deck,
      deck_pos = v_pos + 1,
      current_idx = v_idx,
      card_face = 'back',
      round_locked = false,
      winner = null,
      revealed_at = null,
      round_token = round_token + 1,
      updated_at = now()
  where id = p_room_id and round_locked = true
  returning * into v_room;

  return v_room;
end;
$$;

grant execute on function advance_round(uuid) to anon, authenticated;
