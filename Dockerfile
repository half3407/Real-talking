# ---- 第一阶段:用 Node 构建前端 ----
FROM node:20-alpine AS frontend
WORKDIR /app/frontend
COPY frontend/package*.json ./
RUN npm install
COPY frontend/ ./
RUN npm run build          # 产物在 /app/frontend/dist

# ---- 第二阶段:Python 后端,并把前端产物一起带上 ----
FROM python:3.12-slim
WORKDIR /app
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ ./
# 把上一阶段构建好的前端,复制到后端的 static/(main.py 会从这里端出去)
COPY --from=frontend /app/frontend/dist ./static
ENV PORT=7860
EXPOSE 7860
# 监听 0.0.0.0 + 平台分配的 $PORT
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT}"]
