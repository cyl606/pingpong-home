// ═══════════════════════════════════════════════════════
//  supabase.js  —  乒乓之家全站 Supabase 客户端
//  所有页面引入此文件即可使用 window.sb 和 window.Auth
// ═══════════════════════════════════════════════════════

// ── 1. 配置（填入你的 Supabase 项目信息）──────────────
// 优先读取 setup.html 写入的配置，再读硬编码（直接改这两行也可以）
const SUPABASE_URL  = localStorage.getItem('pp_supabase_url')  || 'https://ypoacsocjijnjrsambrl.supabase.co';
const SUPABASE_ANON = localStorage.getItem('pp_supabase_anon') || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inlwb2Fjc29jamlqbmpyc2FtYnJsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM4MjQzODEsImV4cCI6MjA4OTQwMDM4MX0.N_08SP_4V734nbpVejkNZrZkhQGq99_ZH20Um-arrk0';

// 未配置时给出提示
if (SUPABASE_URL === 'YOUR_SUPABASE_URL') {
  console.warn('[乒乓之家] 未配置 Supabase，请先打开 setup.html 填写配置，或直接编辑 supabase.js 顶部两行。');
}

// ── 2. 加载 Supabase SDK ────────────────────────────────
(function loadSDK() {
  const s = document.createElement('script');
  s.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js';
  s.onload = () => {
    window.sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON);
    document.dispatchEvent(new Event('supabase-ready'));
    Auth._init();
  };
  document.head.appendChild(s);
})();

// ── 3. Auth 模块 ────────────────────────────────────────
window.Auth = {
  _user: null,
  _ready: false,

  // 初始化：监听登录状态
  async _init() {
    const { data: { session } } = await window.sb.auth.getSession();
    this._user = session?.user ?? null;
    this._ready = true;

    window.sb.auth.onAuthStateChange((_event, session) => {
      this._user = session?.user ?? null;
      this._updateNavUI();
      document.dispatchEvent(new CustomEvent('auth-change', { detail: this._user }));
    });

    this._updateNavUI();
  },

  // 当前登录用户（null = 未登录）
  get user() { return this._user; },

  // 邮箱注册
  async signUp(email, password, nickname, city) {
    const { data, error } = await window.sb.auth.signUp({
      email,
      password,
      options: { data: { nickname, city } }
    });
    if (error) throw error;

    // 写入 users 表（触发器会自动创建，但补充 city）
    if (data.user) {
      await window.sb.from('users').upsert({
        id:       data.user.id,
        nickname: nickname || email.split('@')[0],
        city:     city || null,
      });
    }
    return data;
  },

  // 邮箱登录
  async signIn(email, password) {
    const { data, error } = await window.sb.auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  },

  // 退出
  async signOut() {
    await window.sb.auth.signOut();
    location.href = 'pingpong_home.html';
  },

  // 更新导航栏 UI
  _updateNavUI() {
    const nav = document.getElementById('global-nav');
    if (!nav) return;

    const ctaBtn = nav.querySelector('.gnav-cta');
    if (!ctaBtn) return;

    if (this._user) {
      // 已登录：显示头像 + 昵称
      const nickname = this._user.user_metadata?.nickname || this._user.email.split('@')[0];
      ctaBtn.textContent = nickname;
      ctaBtn.href = 'pingpong_level.html';
      ctaBtn.style.background = 'rgba(200,168,75,.15)';
      ctaBtn.style.color = '#C8A84B';
      ctaBtn.style.border = '1px solid rgba(200,168,75,.3)';

      // 加退出按钮
      if (!nav.querySelector('.gnav-signout')) {
        const out = document.createElement('button');
        out.className = 'gnav-signout';
        out.textContent = '退出';
        out.style.cssText = 'background:transparent;border:none;color:rgba(200,200,200,.4);font-size:12px;cursor:pointer;padding:0 10px;transition:color .2s;font-family:inherit;';
        out.onmouseenter = () => out.style.color = '#E86060';
        out.onmouseleave = () => out.style.color = 'rgba(200,200,200,.4)';
        out.onclick = () => Auth.signOut();
        ctaBtn.after(out);
      }
    } else {
      ctaBtn.textContent = '免费注册';
      ctaBtn.href = 'pingpong_register.html';
      ctaBtn.style.background = 'linear-gradient(135deg,#7A601A,#C8A84B)';
      ctaBtn.style.color = '#1A1000';
      ctaBtn.style.border = 'none';
      nav.querySelector('.gnav-signout')?.remove();
    }
  },

  // 需要登录时的保护函数
  requireAuth(redirectBack) {
    if (!this._user) {
      const back = redirectBack || location.href;
      sessionStorage.setItem('auth_redirect', back);
      location.href = 'pingpong_register.html';
      return false;
    }
    return true;
  }
};

// ── 4. 全站数据 API ────────────────────────────────────

window.API = {

  // ── 用户 ─────────────────────────────────────
  async getProfile(userId) {
    const { data, error } = await window.sb
      .from('users')
      .select('*')
      .eq('id', userId)
      .single();
    if (error) throw error;
    return data;
  },

  async updateProfile(updates) {
    if (!Auth.user) throw new Error('未登录');
    const { data, error } = await window.sb
      .from('users')
      .update(updates)
      .eq('id', Auth.user.id)
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  // ── 五行测定 ──────────────────────────────────
  async saveElement(scores) {
    if (!Auth.user) throw new Error('未登录');
    const element = Object.entries(scores)
      .sort((a, b) => b[1] - a[1])[0][0];
    return this.updateProfile({ element, element_scores: scores });
  },

  // ── 开球网积分同步 ────────────────────────────
  async bindKaiqiu(kaiqiuId) {
    if (!Auth.user) throw new Error('未登录');

    // 检查是否已被绑定
    const { data: existing } = await window.sb
      .from('users')
      .select('id')
      .eq('kaiqiu_id', kaiqiuId)
      .neq('id', Auth.user.id)
      .single();
    if (existing) throw new Error('该开球网账号已被其他用户绑定');

    // 模拟从开球网获取积分（正式版替换为真实 API 调用）
    const fakeScore = 1200 + Math.floor(Math.random() * 800);
    const level = Math.min(100, Math.max(1, Math.floor((fakeScore - 1000) / 10)));

    const { data, error } = await window.sb
      .from('users')
      .update({
        kaiqiu_id:        kaiqiuId,
        kaiqiu_score:     fakeScore,
        kaiqiu_synced_at: new Date().toISOString(),
        level,
      })
      .eq('id', Auth.user.id)
      .select()
      .single();
    if (error) throw error;

    // 记录等级历史
    await window.sb.from('level_history').insert({
      user_id:      Auth.user.id,
      level,
      kaiqiu_score: fakeScore,
      reason:       'kaiqiu_bind',
    });

    return { ...data, fakeScore };
  },

  // ── 赛事 ──────────────────────────────────────
  async getTournaments(filters = {}) {
    let q = window.sb
      .from('tournaments')
      .select(`
        *,
        organizer:users!organizer_id(id, nickname, element, level),
        registrations(count)
      `)
      .neq('status', 'draft')
      .order('starts_at', { ascending: false })
      .limit(20);

    if (filters.status) q = q.eq('status', filters.status);
    if (filters.city)   q = q.eq('city', filters.city);

    const { data, error } = await q;
    if (error) throw error;
    return data;
  },

  async createTournament(payload) {
    if (!Auth.user) throw new Error('未登录');
    const { data, error } = await window.sb
      .from('tournaments')
      .insert({ ...payload, organizer_id: Auth.user.id })
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async registerTournament(tournamentId) {
    if (!Auth.requireAuth()) return null;
    const { data, error } = await window.sb
      .from('registrations')
      .insert({ tournament_id: tournamentId, user_id: Auth.user.id })
      .select()
      .single();
    if (error) {
      if (error.code === '23505') throw new Error('你已报名该赛事');
      throw error;
    }
    return data;
  },

  // ── 社区帖子 ──────────────────────────────────
  async getPosts(filters = {}) {
    let q = window.sb
      .from('posts')
      .select(`
        *,
        author:users(id, nickname, element, level, avatar_url)
      `)
      .order('created_at', { ascending: false })
      .limit(20);

    if (filters.element) q = q.eq('element', filters.element);
    if (filters.tag)     q = q.eq('tag', filters.tag);
    if (filters.cursor)  q = q.lt('created_at', filters.cursor);

    const { data, error } = await q;
    if (error) throw error;

    // 如果已登录，查询当前用户的点赞状态
    if (Auth.user && data.length > 0) {
      const ids = data.map(p => p.id);
      const { data: likes } = await window.sb
        .from('post_likes')
        .select('post_id')
        .eq('user_id', Auth.user.id)
        .in('post_id', ids);
      const likedSet = new Set((likes || []).map(l => l.post_id));
      data.forEach(p => { p.liked = likedSet.has(p.id); });
    }
    return data;
  },

  async createPost(body, tag, element) {
    if (!Auth.requireAuth()) return null;
    const { data, error } = await window.sb
      .from('posts')
      .insert({ body, tag, element: element || null, author_id: Auth.user.id })
      .select(`*, author:users(id, nickname, element, level)`)
      .single();
    if (error) throw error;

    // 发帖奖励 +5 积分
    await window.sb.rpc('increment_site_points', {
      uid: Auth.user.id, amount: 5
    }).catch(() => {}); // 忽略积分错误，不影响发帖

    return data;
  },

  async toggleLike(postId) {
    if (!Auth.requireAuth()) return null;
    const { data: existing } = await window.sb
      .from('post_likes')
      .select('post_id')
      .eq('post_id', postId)
      .eq('user_id', Auth.user.id)
      .single();

    if (existing) {
      await window.sb.from('post_likes')
        .delete()
        .eq('post_id', postId)
        .eq('user_id', Auth.user.id);
      return { liked: false };
    } else {
      await window.sb.from('post_likes')
        .insert({ post_id: postId, user_id: Auth.user.id });
      return { liked: true };
    }
  },

  // ── 等级历史 ──────────────────────────────────
  async getLevelHistory(userId) {
    const { data, error } = await window.sb
      .from('level_history')
      .select('*')
      .eq('user_id', userId)
      .order('recorded_at', { ascending: false })
      .limit(30);
    if (error) throw error;
    return data;
  },
};

// ── 5. 错误处理工具 ────────────────────────────────────
window.handleError = function(error, defaultMsg = '操作失败，请稍后重试') {
  console.error(error);
  const msg = error?.message || defaultMsg;
  // 常见错误中文化
  const map = {
    'Invalid login credentials': '邮箱或密码不正确',
    'User already registered':   '该邮箱已注册，请直接登录',
    'Password should be at least 6 characters': '密码至少需要6位',
    'Email not confirmed':        '请先验证邮箱后再登录',
    'rate limited':               '操作太频繁，请稍后再试',
  };
  for (const [k, v] of Object.entries(map)) {
    if (msg.includes(k)) return v;
  }
  return msg;
};
