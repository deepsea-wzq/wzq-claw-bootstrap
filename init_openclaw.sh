#!/bin/bash

# OpenClaw 定制化初始化脚本 (业务独立目录版)
# 执行顺序：环境初始化 -> 技能部署 -> 插件部署 -> 配置写入 -> 服务重启

set -e

# --- 业务运维目录配置 ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
LOG_DIR="$OPS_DIR/logs"
SKILLS_CACHE="$OPS_DIR/cache/deepsea-skills"
EXT_CACHE="$OPS_DIR/cache/extensions"
CURRENT_DATE=$(date +%Y%m%d)
LOG_FILE="$LOG_DIR/init_$CURRENT_DATE.log"

# 初始化目录并记录日志
mkdir -p "$LOG_DIR" "$SKILLS_CACHE" "$EXT_CACHE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ">>> [1/6] 环境变量同步与注入..."
# 优先使用 WZQ 系列注入变量，若无则使用默认值
LLM_BASE_URL=${LLM_BASE_URL:-"https://api.minimaxi.com/v1"}
LLM_API_KEY=${WZQ_LLMKEY:-${LLM_API_KEY:-"sk-xxx"}}
LLM_PROVIDER_NAME=${LLM_PROVIDER_NAME:-"minimax"}

USER_WS_URL=${USER_WS_URL:-"wss://wzq.tenpay.com/ws/openclaw"}
USER_WS_TOKEN=${WZQ_APIKEY:-${USER_WS_TOKEN:-"user-token-xyz"}}

echo ">>> [2/6] 拉取并部署深海技能..."
# 环境变量已通过 export 传递给子脚本
bash "$(dirname "$0")/manage_skills.sh" || echo "警告: 技能同步脚本执行异常，跳过"

echo ">>> [3/6] 安装 wzq-channel 插件..."
EXT_DIR="$EXT_CACHE/wzq-channel"
if [ ! -d "$EXT_DIR/.git" ]; then
    timeout 60s git clone --depth 1 "https://github.com/deepsea-wzq/wzq_channel" "$EXT_DIR" || { echo "拉取插件失败"; exit 1; }
else
    timeout 60s git -C "$EXT_DIR" pull
fi

# 关键修复：增量处理信任名单。如果当前插件缺失导致死锁（CLI 无法启动），直接修正配置文件
CLAW_CONFIG="$HOME/.openclaw/openclaw.json"
if [ -f "$CLAW_CONFIG" ]; then
    if ! openclaw config get "plugins.allow" &>/dev/null; then
        echo "检测到 wzq-channel 可能导致配置死锁，正在执行强力清理以解除限制..."
        # 移除可能导致校验失败的插件项
        sed -i 's/"wzq-channel"//g; s/,,/,/g; s/\[,/[/g; s/,]/]/g' "$CLAW_CONFIG"
    fi
fi

# 改为手工安装：OpenClaw 官方命令可能存在依赖安装不完全或死锁的问题
echo "正在手动安装插件 (复制源码与安装依赖)..."
PLUGIN_TARGET_DIR="$HOME/.openclaw/extensions/wzq-channel"
mkdir -p "$HOME/.openclaw/extensions"
rm -rf "$PLUGIN_TARGET_DIR"
cp -r "$EXT_DIR" "$PLUGIN_TARGET_DIR"

# 手动安装依赖 (优先使用 pnpm，因为 OpenClaw 自身使用 pnpm)
echo "正在执行插件依赖安装 (pnpm/npm install)..."
(cd "$PLUGIN_TARGET_DIR" && {
    if command -v pnpm &> /dev/null; then
        pnpm install --prod
    else
        npm install
    fi
}) || { echo "插件依赖安装失败"; exit 1; }

echo ">>> [4/6] 写入 openclaw.json 配置 (增量设置)..."
# 1. 启用插件系统并设置 wzq-channel 状态
openclaw config set "plugins.enabled" true
openclaw config set "plugins.entries.wzq-channel.enabled" true

# 2. 增量添加至信任名单 (allow 列表)
CURRENT_ALLOW=$(openclaw config get "plugins.allow" 2>/dev/null || echo "[]")
if [[ $CURRENT_ALLOW != *"wzq-channel"* ]]; then
    if [ "$CURRENT_ALLOW" == "[]" ] || [ -z "$CURRENT_ALLOW" ]; then
        openclaw config set "plugins.allow" "[\"wzq-channel\"]" --strict-json
    else
        # 在数组末尾追加
        NEW_ALLOW="${CURRENT_ALLOW%]*},\"wzq-channel\"]"
        openclaw config set "plugins.allow" "$NEW_ALLOW" --strict-json
    fi
fi

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


# 1. 配置渠道 (包含默认 account 映射)
openclaw config set "channels.wzq-channel" "{
  \"accounts\": {
    \"default\": {
      \"enabled\": true,
      \"token\": \"$USER_WS_TOKEN\",
      \"fileUrl\":\"https://wzq.tenpay.com/svr/openclaw/agent/get_image\",
      \"wsUrl\": \"wss://wzq.tenpay.com/ws/openclaw\"
    }
  }
}" --strict-json

# 2. 启用插件系统及具体插件（已在 plugins 全量配置中合并设置）
# 3. 渠道配置已完成，执行收尾逻辑
echo ">>> [5/6] 重启 gateway 服务..."
# 确保服务已安装（新版本 OpenClaw 需先执行 install）
openclaw gateway install || true
openclaw gateway restart

echo ">>> [6/6] 配置定时监控任务 (Crontab)..."
MONITOR_SCRIPT="$OPS_DIR/bootstrap/monitor_updates.sh"
# 日志重定向由脚本内部处理，Crontab 仅负责触发
CRON_JOB="*/5 * * * * $MONITOR_SCRIPT"
(crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" || true; echo "$CRON_JOB") | crontab -

echo "OpenClaw 初始化脚本执行完毕！"
