#!/bin/bash

# OpenClaw 定制化初始化脚本 (业务独立目录版)
# 执行顺序：环境初始化 -> 技能部署 -> 插件部署 -> 配置写入 -> 服务重启

set -e

# --- 业务运维目录配置 ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
LOG_DIR="$OPS_DIR/logs"
SKILLS_CACHE="$OPS_DIR/cache/deepsea-skills"
CURRENT_DATE=$(date +%Y%m%d)
LOG_FILE="$LOG_DIR/init_$CURRENT_DATE.log"

# 初始化目录并记录日志
mkdir -p "$LOG_DIR" "$SKILLS_CACHE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ">>> [1/6] 环境变量同步与注入..."
# 优先使用 WZQ 系列注入变量，若无则使用默认值
LLM_BASE_URL=${LLM_BASE_URL:-"https://api.minimaxi.com/v1"}
LLM_API_KEY=${WZQ_LLMKEY:-${LLM_API_KEY:-"sk-xxx"}}
LLM_PROVIDER_NAME=${LLM_PROVIDER_NAME:-"minimax"}

USER_WS_URL=${USER_WS_URL:-"wss://wzq.tenpay.com/ws/openclaw"}
USER_WS_TOKEN=${WZQ_APIKEY:-${USER_WS_TOKEN:-"user-token-xyz"}}
ss
echo ">>> [2/6] 拉取并部署深海技能..."
OPENCLAW_HOME="$HOME/.openclaw"
SKILLS_DIR="$OPENCLAW_HOME/skills"
mkdir -p "$SKILLS_DIR"

SKILL_REPOS=(
    "https://github.com/deepsea-wzq/wzq-skills"
    "https://github.com/anthropics/skills"
    "https://github.com/peterskoett/self-improving-agent.git"
    "clawhub:JimLiuxinghai/find-skills"
)

for repo in "${SKILL_REPOS[@]}"; do
    if [[ $repo == clawhub:* ]]; then
        slug=${repo#clawhub:}
        echo "使用 clawhub CLI 安装技能: $slug"
        # 使用 npx clawhub 直接安装到技能目录
        timeout 60s npx clawhub install "$slug" --workdir "$OPENCLAW_HOME" --dir "skills" --no-input || echo "安装 $slug 失败，跳过"
        continue
    fi

    repo_name=$(basename "$repo" .git)
    local_cache="$SKILLS_CACHE/$repo_name"
    
    echo "处理技能仓库: $repo"
    if [ ! -d "$local_cache" ]; then
        timeout 60s git clone --depth 1 "$repo" "$local_cache" || { echo "克隆 $repo 超时，跳过"; continue; }
    else
        timeout 60s git -C "$local_cache" pull || { echo "更新 $repo 超时，跳过"; continue; }
    fi

    # 遍历包含 SKILL.md 的目录进行部署
    find "$local_cache" -name "SKILL.md" | while read -r skill_md; do
        skill_src_dir=$(dirname "$skill_md")
        skill_id=$(basename "$skill_src_dir")
        [ "$skill_src_dir" == "$local_cache" ] && continue
        
        echo "部署技能: $skill_id"
        rm -rf "$SKILLS_DIR/$skill_id"
        cp -r "$skill_src_dir" "$SKILLS_DIR/$skill_id"
    done
done

echo ">>> [3/6] 拉取并部署 wzq-channel 插件..."
EXT_DIR="$OPENCLAW_HOME/extensions/wzq-channel"
mkdir -p "$(dirname "$EXT_DIR")"
if [ ! -d "$EXT_DIR/.git" ]; then
    timeout 60s git clone "https://github.com/deepsea-wzq/wzq_channel" "$EXT_DIR" || { echo "拉取插件失败"; exit 1; }
else
    timeout 60s git -C "$EXT_DIR" pull
fi

echo "安装插件运行时依赖..."
cd "$EXT_DIR"
timeout 300s pnpm install --prod || npm install --prod

echo ">>> [4/6] 写入 openclaw.json 配置 (使用 openclaw config set)..."
# 优先设置插件信任名单，防止后续配置命令触发警告
openclaw config set "plugins.allow" '["wzq-channel"]' --strict-json

# 模型配置 (使用全量 JSON 写入方式)
openclaw config set "models.providers.$LLM_PROVIDER_NAME" "{
  \"api\": \"openai-completions\",
  \"baseUrl\": \"$LLM_BASE_URL\",
  \"apiKey\": \"$LLM_API_KEY\",
  \"models\": [
    {
      \"id\": \"MiniMax-M2.5\",
      \"name\": \"MiniMax M2.5\",
      \"contextWindow\": 200000,
      \"maxTokens\": 8192
    },
    {
      \"id\": \"MiniMax-M2.5-highspeed\",
      \"name\": \"MiniMax M2.5 Highspeed\",
      \"contextWindow\": 200000,
      \"maxTokens\": 8192
    }
  ]
}" --strict-json

openclaw config set "agents.defaults.model.primary" "$LLM_PROVIDER_NAME/MiniMax-M2.5-highspeed"

# 1. 配置渠道
openclaw config set "channels.wzq-channel.enabled" true
openclaw config set "channels.wzq-channel.wsUrl" "$USER_WS_URL"
openclaw config set "channels.wzq-channel.token" "$USER_WS_TOKEN"
openclaw config set "channels.wzq-channel.allowFrom" '["*"]' --strict-json

# 2. 启用插件系统及具体插件
openclaw config set "plugins.enabled" true
openclaw config set "plugins.entries.wzq-channel.enabled" true

echo ">>> [5/6] 重启 gateway 服务..."
# 确保服务已安装（新版本 OpenClaw 需先执行 install）
openclaw gateway install || true
openclaw gateway restart

echo ">>> [6/6] 配置定时监控任务 (Crontab)..."
MONITOR_SCRIPT="$OPS_DIR/bootstrap/monitor_updates.sh"
# 日志重定向由脚本内部处理，Crontab 仅负责触发
CRON_JOB="*/5 * * * * $MONITOR_SCRIPT"
(crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT"; echo "$CRON_JOB") | crontab -

echo "OpenClaw 初始化脚本执行完毕！"
