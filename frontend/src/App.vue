<script setup>
import { ref, computed, onMounted, nextTick } from 'vue'

// —— 设置:key 只存在浏览器 localStorage,绝不发去后端存库 ——
const apiKey = ref(localStorage.getItem('rt_api_key') || '')
const baseUrl = 'https://api.deepseek.com/v1'

// 模型:下拉选常用的;选"自定义"时可手填任意 OpenAI 兼容模型名
const modelSelect = ref('deepseek-chat')
const customModel = ref('')
const model = computed(() =>
  modelSelect.value === '__custom__' ? customModel.value.trim() : modelSelect.value
)

// 人格:页面加载时从后端拉列表。selectedIds 是"有序"的——点击顺序 = 发言顺序
const personas = ref([])           // [{ id, name, emoji }]
const selectedIds = ref([])        // 例如 ['gentle', 'feng']

function togglePersona(id) {
  if (loading.value) return        // 一轮对话进行中,先别改选择
  const i = selectedIds.value.indexOf(id)
  if (i === -1) selectedIds.value.push(id)   // 没选过 → 加到队尾(最后发言)
  else selectedIds.value.splice(i, 1)        // 已选 → 取消
}
function orderOf(id) {             // 这个人格排第几个发言(没选中返回 0)
  return selectedIds.value.indexOf(id) + 1
}

const input = ref('')
const messages = ref([])      // 当前对话的消息;每条:{ role, content, persona? }
const loading = ref(false)
const chatBox = ref(null)
const stick = ref(true)   // 是否"粘"在底部自动跟随;用户往上翻时变 false

// —— 多对话持久化:存一个"对话列表",而不是单段对话 ——
// 每段对话:{ id, title, updatedAt, messages: [...] };再单独记"当前打开的是哪段"
const conversations = ref([])     // 所有对话
const currentId = ref(null)       // 当前对话的 id
const sortedConversations = computed(() =>
  [...conversations.value].sort((a, b) => b.updatedAt - a.updatedAt)   // 最近活跃的排前面
)

function genId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 7)
}
function deriveTitle(msgs) {       // 用第一条用户消息当标题
  const firstUser = msgs.find(m => m.role === 'user')
  if (!firstUser) return '新对话'
  return firstUser.content.replace(/\s+/g, ' ').trim().slice(0, 18) || '新对话'
}
function persistConversations() {
  try { localStorage.setItem('rt_conversations', JSON.stringify(conversations.value)) } catch (e) {}
}
function saveCurrentId() {
  try { localStorage.setItem('rt_current_id', currentId.value || '') } catch (e) {}
}

// 把当前 messages 同步进"当前对话"并存盘。每发一句、每个人格说完都调一次。
function saveConversation() {
  if (!currentId.value) {                 // 还没有当前对话就新建一个
    currentId.value = genId()
    conversations.value.unshift({ id: currentId.value, title: '', updatedAt: Date.now(), messages: messages.value })
    saveCurrentId()
  }
  const conv = conversations.value.find(c => c.id === currentId.value)
  if (conv) {
    conv.messages = messages.value
    conv.updatedAt = Date.now()
    if (!conv.title) conv.title = deriveTitle(messages.value)
  }
  persistConversations()
}

function newConversation() {
  // 当前对话已经是空的,就别再建一堆空白对话了
  const cur = conversations.value.find(c => c.id === currentId.value)
  if (cur && cur.messages.length === 0) return
  const id = genId()
  conversations.value.unshift({ id, title: '', updatedAt: Date.now(), messages: [] })
  currentId.value = id
  messages.value = conversations.value[0].messages
  saveCurrentId()
  persistConversations()
  stick.value = true
}

function switchConversation(id) {
  if (id === currentId.value || loading.value) return   // 回复进行中不切换
  currentId.value = id
  const conv = conversations.value.find(c => c.id === id)
  messages.value = conv ? conv.messages : []
  saveCurrentId()
  stick.value = true
  scrollToBottom()
}

function deleteConversation(id) {
  const i = conversations.value.findIndex(c => c.id === id)
  if (i === -1) return
  conversations.value.splice(i, 1)
  if (id === currentId.value) {           // 删的是当前这段 → 切到最近一段或清空
    if (conversations.value.length) {
      const next = sortedConversations.value[0]
      currentId.value = next.id
      messages.value = next.messages
    } else {
      currentId.value = null
      messages.value = []
    }
    saveCurrentId()
    stick.value = true
    scrollToBottom()
  }
  persistConversations()
}

// 每个人格的气泡底色 —— 想改颜色,改这里就行。
// 左边是人格 id(和后端 PERSONAS 的 key 一致),右边是颜色(#RRGGBB 十六进制)
const PERSONA_COLORS = {
  gentle:    '#fbeaf2',   // 🐰 Tamako
  rational:  '#fff1e6',   // 👩‍⚕️ Doctor
  detective: '#eef7e9',   // 🕵️ Detective
  profit:    '#eaf4ff',   // 💰 Profit
  feng:      '#eeecff',   // 🧔 Feng
}
function personaColor(p) {
  if (!p) return '#ffffff'
  return PERSONA_COLORS[p.id] || '#f0f0f0'   // 没配色的人格用浅灰兜底
}

function saveKey() {
  localStorage.setItem('rt_api_key', apiKey.value)
}

// 用户滚动时判断:离底部够近(80px 内)就继续自动跟随,否则别打扰他往上看
function onScroll() {
  const el = chatBox.value
  if (!el) return
  stick.value = el.scrollHeight - el.scrollTop - el.clientHeight < 80
}

async function scrollToBottom() {
  await nextTick()
  if (chatBox.value) chatBox.value.scrollTop = chatBox.value.scrollHeight
}

// 让一个人格说一轮:把已标注好的历史发给后端,流式写进第 idx 条消息
async function streamOnePersona(payload, personaId, idx) {
  try {
    const res = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messages: payload,
        api_key: apiKey.value,
        base_url: baseUrl,
        model: model.value,
        persona_id: personaId,
        present_ids: selectedIds.value,   // 本场选中的所有人格,用来生成"在场名单"
      }),
    })
    if (!res.ok) throw new Error('后端返回 ' + res.status)

    const reader = res.body.getReader()
    const decoder = new TextDecoder()
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      messages.value[idx].content += decoder.decode(value, { stream: true })
      if (stick.value) await scrollToBottom()   // 只在用户没往上翻时才自动滚
    }
  } catch (e) {
    messages.value[idx].content += `\n[请求失败:${e.message}]`
  }
}

// 回车键的处理:Enter 发送,Ctrl+Enter 换行,输入法组字中的回车忽略
function onKeydown(e) {
  if (e.key !== 'Enter' || e.isComposing) return
  if (e.ctrlKey) {                 // Ctrl+Enter → 在光标处插入换行
    e.preventDefault()
    const ta = e.target
    const start = ta.selectionStart, end = ta.selectionEnd
    input.value = input.value.slice(0, start) + '\n' + input.value.slice(end)
    nextTick(() => { ta.selectionStart = ta.selectionEnd = start + 1 })
    return
  }
  if (e.shiftKey) return           // Shift+Enter → 交给默认(也是换行),不拦
  e.preventDefault()               // 单独的 Enter → 发送
  send()
}

async function send() {
  const text = input.value.trim()
  if (!text || loading.value) return
  if (!apiKey.value) { alert('请先在上方填入你的 API key'); return }
  if (!model.value) { alert('请填写模型名'); return }
  if (selectedIds.value.length === 0) { alert('请至少选一个人格'); return }

  messages.value.push({ role: 'user', content: text })
  input.value = ''
  loading.value = true
  stick.value = true            // 用户刚发言,贴回底部跟随
  await scrollToBottom()
  saveConversation()            // 立刻存一次,这条消息就丢不了了

  try {
    // 圆桌:被选中的人格按顺序依次回复;后说的人能看到前面所有人(和用户)说的话
    for (const pid of selectedIds.value) {
      const persona = personas.value.find(p => p.id === pid)

      // 把整场对话拼成一份"每行都标了说话人"的记录(连用户也标成【用户】),
      // 末尾明确命令"现在请你以 X 的身份发言"。谁是谁一清二楚,模型就不会
      // 冒充别的人格、也不会替"用户"续写。
      const speakerName = persona ? persona.name : '你'
      const transcript = messages.value.map(m => {
        const who = m.role === 'user' ? '用户' : (m.persona ? m.persona.name : 'AI')
        return `【${who}】${m.content}`
      }).join('\n')
      const payload = [{
        role: 'user',
        content:
          '下面是这场多人对话的完整记录,每行开头【】里是说话人(【用户】是真正的用户,其余是在场的 AI):\n\n' +
          transcript +
          `\n\n现在轮到你以【${speakerName}】的身份发言。只输出你自己要说的话,` +
          '不要加名字前缀,不要替"用户"或其他人说话、复述或续写他们的话。',
      }]

      // 放一条空占位(记下是哪个人格),再流式填充
      messages.value.push({ role: 'assistant', content: '', persona })
      const idx = messages.value.length - 1
      if (stick.value) await scrollToBottom()

      await streamOnePersona(payload, pid, idx)   // 等这个人说完,再轮到下一个
      // 兜底:万一模型仍自作主张加了【名字】前缀,削掉开头那个
      messages.value[idx].content = messages.value[idx].content.replace(/^\s*【[^】]*】\s*/, '')
      saveConversation()                          // 每个人格说完都存一次
    }
  } finally {
    loading.value = false
  }
}

onMounted(async () => {
  // 1) 恢复对话列表 + 当前对话 id
  try {
    conversations.value = JSON.parse(localStorage.getItem('rt_conversations') || '[]')
  } catch (e) { conversations.value = [] }
  currentId.value = localStorage.getItem('rt_current_id') || null

  // 2) 迁移:把旧版单段对话(rt_messages)转成一段,别让用户丢了
  const legacy = localStorage.getItem('rt_messages')
  if (legacy && conversations.value.length === 0) {
    try {
      const msgs = JSON.parse(legacy)
      if (msgs && msgs.length) {
        const id = genId()
        conversations.value = [{ id, title: deriveTitle(msgs), updatedAt: Date.now(), messages: msgs }]
        currentId.value = id
        persistConversations()
        saveCurrentId()
      }
    } catch (e) {}
    localStorage.removeItem('rt_messages')
  }

  // 3) 载入当前对话的消息
  let cur = conversations.value.find(c => c.id === currentId.value)
  if (!cur && conversations.value.length) {        // 没有有效的当前 id 就用最近一段
    cur = sortedConversations.value[0]
    currentId.value = cur.id
    saveCurrentId()
  }
  if (cur) messages.value = cur.messages
  await scrollToBottom()   // 滚到最新消息(底部)

  // 4) 拉人格列表
  try {
    const res = await fetch('/api/personas')
    personas.value = await res.json()
    if (personas.value.length) selectedIds.value = [personas.value[0].id]
  } catch (e) {
    console.error('拉取人格列表失败,后端开了吗?', e)
  }
})
</script>

<template>
  <div class="app">
    <!-- 最左:窄图标栏(三种模式 + 头像) -->
    <nav class="rail">
      <div class="rail-orb" aria-hidden="true"></div>
      <button class="rail-btn active" type="button" title="多人格圆桌(当前模式)">💬</button>
      <button class="rail-btn" type="button" disabled title="情景描述 · 即将上线">🎭</button>
      <button class="rail-btn" type="button" disabled title="长线深聊 · 即将上线">🌱</button>
      <span class="rail-spacer"></span>
      <div class="rail-avatar" aria-hidden="true">你</div>
    </nav>

    <!-- 中间:最近对话 -->
    <aside class="sidebar">
      <button class="new-btn" type="button" @click="newConversation">
        新对话 <span class="plus">＋</span>
      </button>
      <div class="conv-list">
        <div v-for="c in sortedConversations" :key="c.id"
             :class="['conv-item', { active: c.id === currentId }]"
             @click="switchConversation(c.id)">
          <span class="conv-title">{{ c.title || '新对话' }}</span>
          <button class="conv-del" type="button" title="删除这段对话"
                  @click.stop="deleteConversation(c.id)">×</button>
        </div>
        <p v-if="sortedConversations.length === 0" class="conv-empty">还没有对话</p>
      </div>
    </aside>

    <!-- 右:主聊天面板 -->
    <main class="main">
      <header class="topbar">
        <div class="brand">Real Talking <span>🗣️</span></div>
        <div class="settings">
          <input v-model="apiKey" @blur="saveKey" type="password"
                 placeholder="你的 DeepSeek API key(只存在本机)" />
          <select v-model="modelSelect" class="model">
            <option value="deepseek-chat">deepseek-chat · V3</option>
            <option value="deepseek-reasoner">deepseek-reasoner · R1</option>
            <option value="__custom__">自定义…</option>
          </select>
          <input v-if="modelSelect === '__custom__'" v-model="customModel" class="custom-model"
                 placeholder="模型名,如 gpt-4o-mini" />
        </div>
      </header>

      <p class="hint">选一个或多个人格(数字 = 发言顺序),它们会依次回应你</p>
      <div class="personas">
        <button v-for="p in personas" :key="p.id" type="button"
                :class="['persona-card', { active: selectedIds.includes(p.id) }]"
                :style="{ '--tint': personaColor(p) }"
                @click="togglePersona(p.id)">
          <span v-if="orderOf(p.id)" class="order">{{ orderOf(p.id) }}</span>
          <span class="p-emoji">{{ p.emoji }}</span>
          <span class="p-name">{{ p.name }}</span>
        </button>
      </div>

      <div class="chat" ref="chatBox" @scroll="onScroll">
        <div v-if="messages.length === 0" class="hero">
          <div class="hero-orb" aria-hidden="true"></div>
          <h2 class="hero-title">嗨,我在听 👋</h2>
          <p class="hero-sub">你可以说真心话，我想们我会一直在。</p>
        </div>
        <div v-for="(m, i) in messages" :key="i" :class="['row', m.role]">
          <div class="bubble"
               :style="m.role === 'assistant' && m.persona ? { background: personaColor(m.persona) } : null">
            <div v-if="m.role === 'assistant' && m.persona" class="who">
              <span class="who-emoji">{{ m.persona.emoji }}</span>
              <span class="who-name">{{ m.persona.name }}</span>
            </div>
            {{ m.content || '…' }}
          </div>
        </div>
      </div>

      <form class="composer" @submit.prevent="send">
        <textarea v-model="input" rows="2" :disabled="loading"
                  placeholder="说点真心话…    Enter 发送 · Ctrl+Enter 换行"
                  @keydown="onKeydown"></textarea>
        <button class="send-btn" :disabled="loading" :title="loading ? '思考中' : '发送'">
          <span v-if="loading">…</span>
          <span v-else>↑</span>
        </button>
      </form>
    </main>
  </div>
</template>

<!-- 全局重置:去掉 body 边距,让整页铺满 -->
<style>
html, body, #app { margin: 0; height: 100%; }
body { background: #ececef; }
</style>

<style scoped>
.app, .app * { box-sizing: border-box; }
.app {
  /* —— 设计 tokens:想统一改风格,调这里 —— */
  --bg: #ececef;
  --panel: #ffffff;
  --ink: #1d1d22;
  --muted: #8b8b93;
  --line: #eeeef0;
  --accent: #5b7cfa;
  --accent-soft: #eef2ff;
  --radius: 22px;
  --radius-sm: 14px;
  --shadow: 0 1px 2px rgba(0,0,0,.04), 0 10px 28px rgba(0,0,0,.05);

  display: flex;
  gap: 12px;
  height: 100vh;
  padding: 12px;
  background: var(--bg);
  color: var(--ink);
  font-family: system-ui, -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
  font-size: 15px;
}

/* ---- 最左:图标栏 ---- */
.rail { flex: 0 0 64px; background: var(--panel); border-radius: var(--radius); box-shadow: var(--shadow);
        display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 14px 0; }
.rail-orb { width: 30px; height: 30px; border-radius: 50%; margin-bottom: 6px;
            background: radial-gradient(circle at 32% 30%, #8aa6ff, #5b7cfa 60%, #3550d8); }
.rail-btn { width: 42px; height: 42px; border: none; border-radius: 14px; background: transparent;
            cursor: pointer; font-size: 19px; display: flex; align-items: center; justify-content: center;
            transition: background .15s; }
.rail-btn:hover:not(:disabled) { background: #f3f4f8; }
.rail-btn.active { background: var(--ink); }
.rail-btn:disabled { opacity: .35; cursor: not-allowed; }
.rail-spacer { flex: 1; }
.rail-avatar { width: 34px; height: 34px; border-radius: 50%; background: #eef0f4; color: var(--muted);
               display: flex; align-items: center; justify-content: center; font-size: 13px; }

/* ---- 中间:对话列表 ---- */
.sidebar { flex: 0 0 220px; background: var(--panel); border-radius: var(--radius); box-shadow: var(--shadow);
           padding: 14px; display: flex; flex-direction: column; gap: 10px; min-height: 0; }
.new-btn { display: flex; align-items: center; justify-content: space-between; padding: 11px 14px;
           border: none; border-radius: var(--radius-sm); background: var(--ink); color: #fff;
           cursor: pointer; font-size: 14px; font-weight: 500; }
.new-btn:hover { opacity: .9; }
.new-btn .plus { font-size: 16px; }
.conv-list { display: flex; flex-direction: column; gap: 2px; overflow-y: auto; min-height: 0; }
.conv-item { display: flex; align-items: center; gap: 6px; padding: 9px 11px; border-radius: 11px;
             cursor: pointer; font-size: 13.5px; color: #55555c; }
.conv-item:hover { background: #f5f6f8; }
.conv-item.active { background: var(--accent-soft); color: var(--ink); }
.conv-title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.conv-del { border: none; background: transparent; color: #bcbcc4; cursor: pointer; font-size: 17px;
            line-height: 1; padding: 0 2px; visibility: hidden; }
.conv-item:hover .conv-del { visibility: visible; }
.conv-del:hover { color: #ec5b5b; }
.conv-empty { font-size: 12.5px; color: #bcbcc4; text-align: center; margin-top: 16px; }

/* ---- 右:主面板 ---- */
.main { flex: 1; min-width: 0; background: var(--panel); border-radius: var(--radius); box-shadow: var(--shadow);
        padding: 18px 22px; display: flex; flex-direction: column; min-height: 0; }
.topbar { display: flex; align-items: center; gap: 14px; margin-bottom: 14px; flex-wrap: wrap; }
.brand { font-size: 18px; font-weight: 650; white-space: nowrap; }
.settings { display: flex; gap: 8px; flex: 1; min-width: 220px; }
.settings input, .settings select { padding: 9px 12px; border: 1px solid var(--line); border-radius: 11px;
            background: #fafafb; font: inherit; color: var(--ink); outline: none; }
.settings input { flex: 1; min-width: 0; }
.settings input:focus, .settings select:focus { border-color: var(--accent); background: #fff; }
.settings .model { flex: 0 0 auto; cursor: pointer; }
.settings .custom-model { flex: 0 0 150px; }
.hint { font-size: 12.5px; color: var(--muted); margin: 0 0 10px; }

/* 人格胶囊 */
.personas { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 14px; }
.persona-card { position: relative; display: flex; align-items: center; gap: 8px; padding: 8px 14px 8px 10px;
                border: 1.5px solid var(--line); border-radius: 999px; background: #fff; cursor: pointer;
                font: inherit; color: var(--ink); transition: border-color .15s, background .15s; }
.persona-card:hover { border-color: #d6d6dc; }
.persona-card.active { border-color: transparent; background: var(--tint); box-shadow: 0 0 0 1.5px rgba(0,0,0,.06) inset; }
.persona-card .p-emoji { font-size: 20px; line-height: 1; }
.persona-card .p-name { font-size: 13.5px; font-weight: 500; }
.persona-card .order { position: absolute; top: -6px; left: -6px; width: 19px; height: 19px; background: var(--ink);
                       color: #fff; border-radius: 50%; font-size: 11px; font-weight: 600;
                       display: flex; align-items: center; justify-content: center; }

/* 对话区 */
.chat { flex: 1; overflow-y: auto; min-height: 0; display: flex; flex-direction: column; gap: 12px; padding: 6px 4px; }
.hero { margin: auto; text-align: center; padding: 20px; }
.hero-orb { width: 72px; height: 72px; border-radius: 50%; margin: 0 auto 18px;
            background: radial-gradient(circle at 32% 28%, #9fb6ff, #5b7cfa 58%, #324fd6);
            box-shadow: 0 10px 30px rgba(91,124,250,.35); }
.hero-title { font-size: 26px; font-weight: 650; margin: 0 0 8px; }
.hero-sub { font-size: 15px; color: var(--muted); margin: 0; }
.row { display: flex; }
.row.user { justify-content: flex-end; }
.bubble { padding: 11px 15px; border-radius: 18px; max-width: 76%; white-space: pre-wrap; line-height: 1.55; font-size: 14.5px; }
.row.user .bubble { background: var(--ink); color: #fff; border-bottom-right-radius: 6px; }
.row.assistant .bubble { background: #f5f6f8; border-bottom-left-radius: 6px; }
.who { display: flex; align-items: center; gap: 7px; margin-bottom: 6px; }
.who-emoji { font-size: 22px; line-height: 1; }
.who-name { font-size: 15px; font-weight: 700; color: #3a3a40; }

/* 输入条 */
.composer { display: flex; align-items: flex-end; gap: 10px; margin-top: 12px; padding: 8px 8px 8px 16px;
            border: 1px solid var(--line); border-radius: var(--radius); background: #fafafb; }
.composer:focus-within { border-color: #d6d6dc; background: #fff; }
.composer textarea { flex: 1; border: none; background: transparent; resize: none; outline: none; font: inherit;
                     line-height: 1.5; padding: 6px 0; max-height: 140px; color: var(--ink); }
.send-btn { flex: 0 0 auto; width: 40px; height: 40px; border: none; border-radius: 50%; background: var(--ink);
            color: #fff; cursor: pointer; font-size: 18px; display: flex; align-items: center; justify-content: center; }
.send-btn:disabled { background: #bcbcc4; cursor: not-allowed; }
</style>
