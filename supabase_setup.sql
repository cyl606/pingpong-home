-- ═══════════════════════════════════════════════════════════
--  乒乓之家 · Supabase 数据库完整迁移脚本
--  文件: supabase/migrations/001_initial_schema.sql
-- ═══════════════════════════════════════════════════════════

-- ── 扩展 ──────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- 模糊搜索

-- ── 枚举类型 ──────────────────────────────────────────────
CREATE TYPE element_type AS ENUM ('jin', 'mu', 'shui', 'huo', 'tu');

CREATE TYPE tournament_format AS ENUM (
  'single_elim',      -- 单败淘汰
  'double_elim',      -- 双败淘汰
  'round_robin',      -- 单循环
  'group_knockout'    -- 小组赛+淘汰
);

CREATE TYPE tournament_status AS ENUM (
  'draft',            -- 草稿（未发布）
  'open',             -- 开放报名
  'in_progress',      -- 进行中
  'finished'          -- 已结束
);

CREATE TYPE post_tag AS ENUM ('tips', 'match', 'gear', 'qa');

-- ══════════════════════════════════════════════════════════
--  USERS 用户档案表
--  注：认证信息在 auth.users，此表存储业务数据
-- ══════════════════════════════════════════════════════════
CREATE TABLE users (
  id                uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nickname          varchar(32) NOT NULL,
  city              varchar(20),
  element           element_type,
  element_scores    jsonb,                       -- {"jin":3,"huo":5,...}
  level             smallint    NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 100),
  kaiqiu_id         varchar(64) UNIQUE,          -- 开球网账号 ID
  kaiqiu_score      integer     CHECK (kaiqiu_score >= 0),
  kaiqiu_synced_at  timestamptz,
  site_points       integer     NOT NULL DEFAULT 0 CHECK (site_points >= 0),
  avatar_url        text,
  bio               text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- 等级自动同步触发器
CREATE OR REPLACE FUNCTION sync_level_from_kaiqiu()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.kaiqiu_score IS NOT NULL THEN
    NEW.level := LEAST(100, GREATEST(1,
      FLOOR((NEW.kaiqiu_score - 1000)::numeric / 10)::smallint
    ));
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_kaiqiu_score_update
  BEFORE UPDATE OF kaiqiu_score ON users
  FOR EACH ROW EXECUTE FUNCTION sync_level_from_kaiqiu();

-- updated_at 自动更新
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

-- 用户注册时自动插入档案（从 auth trigger 调用）
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.users (id, nickname)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'nickname', split_part(NEW.email, '@', 1))
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- 索引
CREATE INDEX idx_users_element ON users(element);
CREATE INDEX idx_users_level   ON users(level DESC);
CREATE INDEX idx_users_city    ON users(city);
CREATE INDEX idx_users_kaiqiu  ON users(kaiqiu_id) WHERE kaiqiu_id IS NOT NULL;

-- ══════════════════════════════════════════════════════════
--  TOURNAMENTS 赛事表
-- ══════════════════════════════════════════════════════════
CREATE TABLE tournaments (
  id            uuid              PRIMARY KEY DEFAULT uuid_generate_v4(),
  name          varchar(100)      NOT NULL,
  description   text,
  format        tournament_format NOT NULL,
  status        tournament_status NOT NULL DEFAULT 'draft',
  organizer_id  uuid              NOT NULL REFERENCES users(id),
  level_min     smallint          CHECK (level_min BETWEEN 1 AND 100),
  level_max     smallint          CHECK (level_max BETWEEN 1 AND 100),
  max_players   smallint          NOT NULL CHECK (max_players > 0),
  venue         varchar(200),
  city          varchar(20),
  prize         varchar(100),
  starts_at     timestamptz       NOT NULL,
  reg_deadline  timestamptz       NOT NULL,
  is_ranked     boolean           NOT NULL DEFAULT true,
  element_filter element_type,              -- NULL = 全部风格可参加
  created_at    timestamptz       NOT NULL DEFAULT now(),
  updated_at    timestamptz       NOT NULL DEFAULT now(),

  CONSTRAINT deadline_before_start CHECK (reg_deadline <= starts_at),
  CONSTRAINT level_range_valid     CHECK (
    level_min IS NULL OR level_max IS NULL OR level_min <= level_max
  )
);

CREATE TRIGGER touch_tournaments
  BEFORE UPDATE ON tournaments
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_tournaments_status     ON tournaments(status);
CREATE INDEX idx_tournaments_starts_at  ON tournaments(starts_at DESC);
CREATE INDEX idx_tournaments_organizer  ON tournaments(organizer_id);

-- ══════════════════════════════════════════════════════════
--  REGISTRATIONS 报名表
-- ══════════════════════════════════════════════════════════
CREATE TABLE registrations (
  id              uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  tournament_id   uuid        NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  user_id         uuid        NOT NULL REFERENCES users(id),
  seed            smallint,                -- 种子排名（可选）
  registered_at   timestamptz NOT NULL DEFAULT now(),

  UNIQUE (tournament_id, user_id)
);

CREATE INDEX idx_registrations_tournament ON registrations(tournament_id);
CREATE INDEX idx_registrations_user       ON registrations(user_id);

-- 报名人数视图
CREATE VIEW tournament_player_counts AS
  SELECT tournament_id, COUNT(*) AS player_count
  FROM registrations
  GROUP BY tournament_id;

-- ══════════════════════════════════════════════════════════
--  MATCHES 对阵表
-- ══════════════════════════════════════════════════════════
CREATE TABLE matches (
  id              uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  tournament_id   uuid        NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  round           smallint    NOT NULL,   -- 轮次（0-based）
  position        smallint    NOT NULL,   -- 在该轮次的位置（0-based）
  player_a_id     uuid        REFERENCES users(id),
  player_b_id     uuid        REFERENCES users(id),
  score_a         smallint    CHECK (score_a >= 0),
  score_b         smallint    CHECK (score_b >= 0),
  winner_id       uuid        REFERENCES users(id),
  played_at       timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),

  UNIQUE (tournament_id, round, position),
  CONSTRAINT winner_must_be_player CHECK (
    winner_id IS NULL OR winner_id = player_a_id OR winner_id = player_b_id
  )
);

CREATE INDEX idx_matches_tournament ON matches(tournament_id);
CREATE INDEX idx_matches_players    ON matches(player_a_id, player_b_id);

-- ══════════════════════════════════════════════════════════
--  LEVEL HISTORY 等级历史
-- ══════════════════════════════════════════════════════════
CREATE TABLE level_history (
  id          uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  level       smallint    NOT NULL,
  kaiqiu_score integer,
  reason      varchar(50),               -- 'kaiqiu_sync' | 'manual' | 'tournament'
  recorded_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_lh_user ON level_history(user_id, recorded_at DESC);

-- ══════════════════════════════════════════════════════════
--  POSTS 社区帖子
-- ══════════════════════════════════════════════════════════
CREATE TABLE posts (
  id          uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  author_id   uuid        NOT NULL REFERENCES users(id),
  body        text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
  tag         post_tag    NOT NULL,
  element     element_type,
  image_urls  text[],
  likes_count integer     NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER touch_posts
  BEFORE UPDATE ON posts
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_posts_author    ON posts(author_id);
CREATE INDEX idx_posts_element   ON posts(element);
CREATE INDEX idx_posts_created   ON posts(created_at DESC);
CREATE INDEX idx_posts_body_trgm ON posts USING gin(body gin_trgm_ops);

-- ── 点赞 ──────────────────────────────────────────────────
CREATE TABLE post_likes (
  post_id    uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id)
);

-- 点赞数自动维护
CREATE OR REPLACE FUNCTION update_likes_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE posts SET likes_count = likes_count + 1 WHERE id = NEW.post_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE posts SET likes_count = likes_count - 1 WHERE id = OLD.post_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_post_like_change
  AFTER INSERT OR DELETE ON post_likes
  FOR EACH ROW EXECUTE FUNCTION update_likes_count();

-- ── 关注 ──────────────────────────────────────────────────
CREATE TABLE follows (
  follower_id uuid NOT NULL REFERENCES users(id),
  followee_id uuid NOT NULL REFERENCES users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_id, followee_id),
  CONSTRAINT no_self_follow CHECK (follower_id != followee_id)
);

CREATE INDEX idx_follows_followee ON follows(followee_id);

-- ── 私信 ──────────────────────────────────────────────────
CREATE TABLE messages (
  id          uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  sender_id   uuid        NOT NULL REFERENCES users(id),
  receiver_id uuid        NOT NULL REFERENCES users(id),
  body        text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 1000),
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT no_self_message CHECK (sender_id != receiver_id)
);

CREATE INDEX idx_messages_thread ON messages(
  LEAST(sender_id, receiver_id),
  GREATEST(sender_id, receiver_id),
  created_at DESC
);

-- ══════════════════════════════════════════════════════════
--  RLS 行级安全策略
-- ══════════════════════════════════════════════════════════
ALTER TABLE users         ENABLE ROW LEVEL SECURITY;
ALTER TABLE tournaments   ENABLE ROW LEVEL SECURITY;
ALTER TABLE registrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE matches        ENABLE ROW LEVEL SECURITY;
ALTER TABLE level_history  ENABLE ROW LEVEL SECURITY;
ALTER TABLE posts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE post_likes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE follows        ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages       ENABLE ROW LEVEL SECURITY;

-- users
CREATE POLICY "users: public read"       ON users FOR SELECT USING (true);
CREATE POLICY "users: self update"       ON users FOR UPDATE USING (auth.uid() = id);

-- tournaments
CREATE POLICY "tournaments: public read" ON tournaments FOR SELECT USING (status != 'draft');
CREATE POLICY "tournaments: organizer read draft" ON tournaments FOR SELECT
  USING (auth.uid() = organizer_id);
CREATE POLICY "tournaments: auth insert" ON tournaments FOR INSERT
  WITH CHECK (auth.uid() = organizer_id);
CREATE POLICY "tournaments: organizer update" ON tournaments FOR UPDATE
  USING (auth.uid() = organizer_id);

-- registrations
CREATE POLICY "registrations: read own tournament" ON registrations FOR SELECT
  USING (
    user_id = auth.uid() OR
    EXISTS (SELECT 1 FROM tournaments t WHERE t.id = tournament_id AND t.organizer_id = auth.uid())
  );
CREATE POLICY "registrations: self insert" ON registrations FOR INSERT
  WITH CHECK (auth.uid() = user_id);
CREATE POLICY "registrations: self delete" ON registrations FOR DELETE
  USING (auth.uid() = user_id);

-- matches: everyone can read, only organizers can update
CREATE POLICY "matches: public read"  ON matches FOR SELECT USING (true);
CREATE POLICY "matches: organizer write" ON matches FOR ALL
  USING (
    EXISTS (SELECT 1 FROM tournaments t WHERE t.id = tournament_id AND t.organizer_id = auth.uid())
  );

-- level_history
CREATE POLICY "lh: self read" ON level_history FOR SELECT USING (auth.uid() = user_id);

-- posts
CREATE POLICY "posts: public read"  ON posts FOR SELECT USING (true);
CREATE POLICY "posts: auth insert"  ON posts FOR INSERT WITH CHECK (auth.uid() = author_id);
CREATE POLICY "posts: self update"  ON posts FOR UPDATE USING (auth.uid() = author_id);
CREATE POLICY "posts: self delete"  ON posts FOR DELETE USING (auth.uid() = author_id);

-- post_likes
CREATE POLICY "likes: public read"  ON post_likes FOR SELECT USING (true);
CREATE POLICY "likes: self write"   ON post_likes FOR ALL USING (auth.uid() = user_id);

-- follows
CREATE POLICY "follows: public read" ON follows FOR SELECT USING (true);
CREATE POLICY "follows: self write"  ON follows  FOR ALL USING (auth.uid() = follower_id);

-- messages: only participants
CREATE POLICY "messages: participants read" ON messages FOR SELECT
  USING (auth.uid() = sender_id OR auth.uid() = receiver_id);
CREATE POLICY "messages: auth send" ON messages FOR INSERT
  WITH CHECK (auth.uid() = sender_id);

-- ══════════════════════════════════════════════════════════
--  SEED 初始测试数据（开发环境）
-- ══════════════════════════════════════════════════════════
-- 注：生产环境请删除此段

-- 测试用的存储过程，可从 Supabase Studio 调用
CREATE OR REPLACE FUNCTION seed_dev_data()
RETURNS void AS $$
DECLARE
  u1 uuid := uuid_generate_v4();
  u2 uuid := uuid_generate_v4();
  t1 uuid := uuid_generate_v4();
BEGIN
  -- 此函数仅供开发环境调试，生产中不调用
  RAISE NOTICE '开发测试数据已插入（实际数据通过 auth 注册流程创建）';
END;
$$ LANGUAGE plpgsql;

-- ── 积分累加函数（社区发帖等触发）──────────────────────────
CREATE OR REPLACE FUNCTION increment_site_points(uid uuid, amount integer)
RETURNS void AS $$
BEGIN
  UPDATE users
  SET site_points = site_points + amount
  WHERE id = uid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
