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
    const res = await fetch('http://localhost:8000/api/chat', {
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
    const res = await fetch('http://localhost:8000/api/personas')
    personas.value = await res.json()
    if (personas.value.length) selectedIds.value = [personas.value[0].id]
  } catch (e) {
    console.error('拉取人格列表失败,后端开了吗?', e)
  }
})
</script>

<template>
  <div class="app">
    <!-- 侧边栏:最近对话列表 -->
    <aside class="sidebar">
      <button class="new-btn" type="button" @click="newConversation">＋ 新对话</button>
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

    <!-- 主区:聊天 -->
    <main class="main">
      <h1>Real Talking 🗣️</h1>

      <div class="settings">
        <input v-model="apiKey" @blur="saveKey" type="password"
               placeholder="你的 DeepSeek API key(只存在本机)" />
        <select v-model="modelSelect" class="model">
          <option value="deepseek-chat">deepseek-chat(V3,日常对话)</option>
          <option value="deepseek-reasoner">deepseek-reasoner(R1,深度推理)</option>
          <option value="__custom__">自定义…</option>
        </select>
        <input v-if="modelSelect === '__custom__'" v-model="customModel"
               placeholder="输入模型名,如 gpt-4o-mini" />
      </div>

      <!-- 卡片式人格选择:可多选,卡片上的数字是发言顺序 -->
      <p class="hint">选一个或多个人格(数字 = 发言顺序),它们会依次回应你:</p>
      <div class="personas">
        <div v-for="p in personas" :key="p.id"
             :class="['persona-card', { active: selectedIds.includes(p.id) }]"
             @click="togglePersona(p.id)">
          <span v-if="orderOf(p.id)" class="order">{{ orderOf(p.id) }}</span>
          <span class="emoji">{{ p.emoji }}</span>
          <span class="name">{{ p.name }}</span>
        </div>
      </div>

      <div class="chat" ref="chatBox" @scroll="onScroll">
        <p v-if="messages.length === 0" class="empty">你可以说真心话，我想们我会一直在。</p>
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
        <textarea v-model="input" rows="3" :disabled="loading"
                  placeholder="说点真心话…(Enter 发送,Ctrl+Enter 换行)"
                  @keydown="onKeydown"></textarea>
        <button :disabled="loading">{{ loading ? '思考中…' : '发送' }}</button>
      </form>
    </main>
  </div>
</template>

<style scoped>
.app { display: flex; gap: 16px; max-width: 1000px; margin: 0 auto; padding: 16px;
       font-family: system-ui, -apple-system, sans-serif; }

/* 侧边栏 */
.sidebar { width: 200px; flex-shrink: 0; display: flex; flex-direction: column; gap: 10px; }
.new-btn { padding: 8px 12px; border: 1px solid #ccc; border-radius: 8px; background: #fff;
           cursor: pointer; font-size: 14px; width: 100%; }
.new-btn:hover { background: #f3f3f3; }
.conv-list { display: flex; flex-direction: column; gap: 4px; overflow-y: auto; max-height: 72vh; }
.conv-item { display: flex; align-items: center; gap: 6px; padding: 8px 10px; border-radius: 8px;
             cursor: pointer; font-size: 13px; color: #444; }
.conv-item:hover { background: #f3f3f3; }
.conv-item.active { background: #e8f3ff; color: #111; }
.conv-title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.conv-del { border: none; background: transparent; color: #bbb; cursor: pointer; font-size: 16px;
            line-height: 1; padding: 0 2px; visibility: hidden; }
.conv-item:hover .conv-del { visibility: visible; }
.conv-del:hover { color: #e44; }
.conv-empty { font-size: 12px; color: #bbb; text-align: center; margin-top: 12px; }

/* 主区 */
.main { flex: 1; min-width: 0; }
h1 { font-size: 20px; margin: 0 0 12px; }
.settings { display: flex; gap: 8px; margin-bottom: 12px; flex-wrap: wrap; }
.settings input, .settings select { flex: 1; padding: 8px; border: 1px solid #ccc; border-radius: 8px; }
.settings .model { flex: 0 0 200px; }
.hint { font-size: 13px; color: #888; margin: 0 0 8px; }
.personas { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 12px; }
.persona-card { position: relative; display: flex; flex-direction: column; align-items: center; gap: 2px;
                width: 84px; padding: 10px 6px; border: 2px solid #e3e3e3; border-radius: 12px;
                background: #fff; cursor: pointer; user-select: none; transition: border-color .15s, background .15s; }
.persona-card:hover { border-color: #bdbdbd; }
.persona-card.active { border-color: #4caf50; background: #f1f8f1; }
.persona-card .emoji { font-size: 24px; line-height: 1; }
.persona-card .name { font-size: 12px; color: #555; }
.persona-card .order { position: absolute; top: -8px; right: -8px; width: 20px; height: 20px;
                       background: #4caf50; color: #fff; border-radius: 50%; font-size: 12px;
                       display: flex; align-items: center; justify-content: center; }
.chat { height: 420px; overflow-y: auto; border: 1px solid #eee; border-radius: 12px;
        padding: 16px; display: flex; flex-direction: column; gap: 10px; background: #fafafa; }
.empty { color: #aaa; text-align: center; margin-top: 160px; }
.row { display: flex; }
.row.user { justify-content: flex-end; }
.bubble { padding: 10px 14px; border-radius: 14px; max-width: 78%; white-space: pre-wrap; line-height: 1.5; }
.row.user .bubble { background: #c8e6c9; }
.row.assistant .bubble { background: #fff; border: 1px solid #eee; }
.who { display: flex; align-items: center; gap: 6px; margin-bottom: 6px; }
.who-emoji { font-size: 24px; line-height: 1; }            /* emoji 头像,改这个数字调大小 */
.who-name { font-size: 17px; font-weight: 700; color: #444; }  /* 名字,比正文(16px)略大且加粗 */
.composer { display: flex; gap: 8px; margin-top: 12px; align-items: stretch; }
.composer textarea { flex: 1; padding: 10px; border: 1px solid #ccc; border-radius: 8px;
                     font: inherit; resize: vertical; min-height: 60px; }
.composer button { padding: 10px 20px; border: none; border-radius: 8px; background: #4caf50;
                   color: #fff; cursor: pointer; align-self: stretch; }
.composer button:disabled { background: #aaa; cursor: not-allowed; }
</style>
