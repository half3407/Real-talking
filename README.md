# Real Talking 🗣️

和 AI 进行深度"真心话"对话的小项目。用户倾诉,AI 倾听并给建议。

- 后端:FastAPI(把消息流式转发给大模型)
- 前端:Vue3 + Vite
- 大模型:BYOK(用户自带 key),OpenAI 兼容接口,默认 DeepSeek

## 怎么跑起来(第一步:单人格流式对话)

### 1. 启动后端

```powershell
cd backend
python -m venv .venv
.venv\Scripts\Activate.ps1      # Windows PowerShell
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

后端会跑在 http://localhost:8000

### 2. 启动前端(另开一个终端)

```powershell
cd frontend
npm install
npm run dev
```

打开终端里显示的地址(默认 http://localhost:5173)。

### 3. 开聊

在页面上方填入你的 DeepSeek API key(到 https://platform.deepseek.com 申请),然后就能对话了。

## 安全须知

- 你的 API key 只存在浏览器本机(localStorage),后端只是临时转发、用完即弃,**不存数据库、不打印日志**。
- 真实的 `.env` 文件**绝不要提交到 git**(已在 `.gitignore` 里忽略)。
