#!/bin/bash

# OpenClaw 定制化初始化脚本 (业务独立目录版)
# 执行顺序：环境初始化 -> 技能部署 -> 插件部署 -> MD资源替换 -> 配置写入 -> 服务重启 -> 技能定时任务预配置

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

echo ">>> [1/7] 环境变量同步与注入..."
# 优先使用 WZQ 系列注入变量，若无则使用默认值
LLM_BASE_URL=${LLM_BASE_URL:-"https://proxy.finance.qq.com/cgi/cgi-bin/openai/sse/openclaw/v1"}
LLM_API_KEY=${WZQ_LLMKEY:-${LLM_API_KEY:-""}}
LLM_PROVIDER_NAME=${LLM_PROVIDER_NAME:-"finance-gateway"}

USER_WS_URL=${USER_WS_URL:-"wss://wzq.tenpay.com/ws/openclaw"}
USER_WS_TOKEN=${WZQ_APIKEY:-${USER_WS_TOKEN:-"user-token-xyz"}}

echo ">>> [2/7] 拉取并部署深海技能..."
# 环境变量已通过 export 传递给子脚本
# manage_skills.sh 退出码: 0=无变更, 2=有变更(均为成功), 1=出错
set +e
bash "$(dirname "$0")/manage_skills.sh"
SKILL_SYNC_RC=$?
set -e
if [ $SKILL_SYNC_RC -eq 1 ]; then
    echo "警告: 技能同步脚本执行异常，跳过"
fi

echo ">>> [3/7] 安装 wzq-channel 插件..."
EXT_DIR="$EXT_CACHE/wzq-channel"
if [ ! -d "$EXT_DIR/.git" ]; then
    timeout 60s git clone --depth 1 "https://github.com/deepsea-wzq/wzq_channel" "$EXT_DIR" || { echo "拉取插件失败"; exit 1; }
else
    timeout 60s git -C "$EXT_DIR" pull
fi

# 关键修复：增量处理信任名单。如果当前插件缺失导致死锁（CLI 无法启动），直接修正配置文件
CLAW_CONFIG="$HOME/.openclaw/openclaw.json"
if [ -f "$CLAW_CONFIG" ]; then
    if ! timeout 15s openclaw config get "plugins.allow" &>/dev/null; then
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

# 手动安装依赖 (优先使用 npm)
echo "正在执行插件依赖安装 (npm install)..."
(cd "$PLUGIN_TARGET_DIR" && {
    if command -v npm &> /dev/null; then
        timeout 180s npm install
    elif command -v pnpm &> /dev/null; then
        echo "警告: npm 不可用，回退到 pnpm install --prod"
        timeout 180s pnpm install --prod
    else
        echo "错误: 未找到 npm 或 pnpm"
        exit 1
    fi
}) || { echo "插件依赖安装失败"; exit 1; }

echo ">>> [4/7] 下载 wzq-claw-md 资源并替换本地文件..."
MD_DONE_FLAG="$OPS_DIR/.wzq-claw-md-done"
if [ ! -f "$MD_DONE_FLAG" ]; then
    MD_CACHE="$OPS_DIR/cache/wzq-claw-md"
    MD_BACKUP="$OPS_DIR/backup/openclaw-pre-md"
    rm -rf "$MD_CACHE"
    timeout 120s git clone --depth 1 "https://github.com/deepsea-wzq/wzq-claw-md" "$MD_CACHE" || { echo "拉取 wzq-claw-md 失败"; exit 1; }

    OPENCLAW_DIR="$HOME/.openclaw/workspace"
    mkdir -p "$OPENCLAW_DIR"

    # --- 备份即将被覆盖的旧文件 ---
    echo "正在备份即将被覆盖的旧文件到 $MD_BACKUP ..."
    rm -rf "$MD_BACKUP"
    mkdir -p "$MD_BACKUP"
    # 遍历仓库中的文件，将本地对应的旧文件按原目录结构备份
    find "$MD_CACHE" -mindepth 1 -not -path '*/.git/*' -not -name '.git' -type f | while read -r src; do
        rel="${src#$MD_CACHE/}"
        target="$OPENCLAW_DIR/$rel"
        if [ -f "$target" ]; then
            mkdir -p "$(dirname "$MD_BACKUP/$rel")"
            cp -f "$target" "$MD_BACKUP/$rel"
        fi
    done
    echo "备份完成 (共 $(find "$MD_BACKUP" -type f 2>/dev/null | wc -l) 个文件)"

    # --- 将仓库内文件覆盖到本地 openclaw 目录（排除 .git 元数据）---
    rsync -av --exclude='.git' "$MD_CACHE/" "$OPENCLAW_DIR/" || {
        # rsync 不可用时回退到 cp
        echo "rsync 不可用，回退到 cp 覆盖..."
        find "$MD_CACHE" -mindepth 1 -not -path '*/.git/*' -not -name '.git' | while read -r src; do
            rel="${src#$MD_CACHE/}"
            if [ -d "$src" ]; then
                mkdir -p "$OPENCLAW_DIR/$rel"
            else
                mkdir -p "$(dirname "$OPENCLAW_DIR/$rel")"
                cp -f "$src" "$OPENCLAW_DIR/$rel"
            fi
        done
    }

    echo "wzq-claw-md 资源替换完成"
    # 写入标记文件，后续重复执行 init 时跳过此步骤
    touch "$MD_DONE_FLAG"
else
    echo "wzq-claw-md 已初始化过，跳过 (标记文件: $MD_DONE_FLAG)"
fi

echo ">>> [5/7] 写入 openclaw.json 配置 (增量设置)..."
# 1. 启用插件系统并设置 wzq-channel 状态
timeout 15s openclaw config set "plugins.enabled" true
timeout 15s openclaw config set "plugins.entries.wzq-channel.enabled" true

# 2. 增量添加至信任名单 (allow 列表)
CURRENT_ALLOW=$(timeout 15s openclaw config get "plugins.allow" 2>/dev/null || echo "[]")
if [[ $CURRENT_ALLOW != *"wzq-channel"* ]]; then
    if [ "$CURRENT_ALLOW" == "[]" ] || [ -z "$CURRENT_ALLOW" ]; then
        timeout 15s openclaw config set "plugins.allow" "[\"wzq-channel\"]" --strict-json
    else
        # 在数组末尾追加
        NEW_ALLOW="${CURRENT_ALLOW%]*},\"wzq-channel\"]"
        timeout 15s openclaw config set "plugins.allow" "$NEW_ALLOW" --strict-json
    fi
fi

# 模型配置 (使用全量 JSON 写入方式)
timeout 15s openclaw config set "models.providers.$LLM_PROVIDER_NAME" "{
  \"baseUrl\": \"$LLM_BASE_URL\",
  \"apiKey\": \"$LLM_API_KEY\",
  \"api\": \"openai-completions\",
  \"models\": [
    {
      \"id\": \"claude-sonnet-4-6\",
      \"name\": \"claude-sonnet-4-6\",
      \"contextWindow\": 200000,
      \"maxTokens\": 50000,
      \"input\":[\"text\",\"image\"]
    }
  ]
}" --strict-json

timeout 15s openclaw config set "agents.defaults.model.primary" "$LLM_PROVIDER_NAME/claude-sonnet-4-6"

# 注入关键环境变量到 openclaw 运行时，确保 crontab 等非交互式环境下服务也能获取
if [ -n "$WZQ_APIKEY" ]; then
    timeout 15s openclaw config set "env.vars.WZQ_APIKEY" "$WZQ_APIKEY"
fi

# 1. 配置渠道 (包含默认 account 映射)
timeout 15s openclaw config set "channels.wzq-channel" "{
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
echo ">>> [6/8] 重启 gateway 服务..."
# 确保服务已安装（新版本 OpenClaw 需先执行 install）
timeout 60s openclaw gateway install || true
timeout 60s openclaw gateway restart

echo ">>> [7/8] 预配置 skill 定时任务 (disabled)..."
# gateway 启动后才能操作 cron，等待就绪
sleep 10

# --- Market Pulse 盘前/盘后定时任务 ---
# 检查是否已存在，避免重复创建；创建为 disabled 状态，用户确认后自行启用
set +e
if ! openclaw cron list --json 2>/dev/null | grep -q "market-pulse-premarket"; then
  openclaw cron create \
    --name "market-pulse-premarket" \
    --cron "30 8 * * 1-5" \
    --tz "Asia/Shanghai" \
    --session main \
    --system-event "盘前分析｜要闻·行情·资金·自选股" \
    --description "每个交易日8:30自动推送盘前全景分析。当前未启用，对我说「开启盘前分析」即可。" \
    --disabled \
  && echo "market-pulse-premarket 创建成功 (disabled)" \
  || echo "警告: market-pulse-premarket 创建失败"
else
  echo "market-pulse-premarket 已存在，跳过"
fi

if ! openclaw cron list --json 2>/dev/null | grep -q "market-pulse-postmarket"; then
  openclaw cron create \
    --name "market-pulse-postmarket" \
    --cron "30 16 * * 1-5" \
    --tz "Asia/Shanghai" \
    --session main \
    --system-event "盘后复盘｜涨跌·板块·资金·自选股" \
    --description "每个交易日16:30自动推送盘后复盘分析。当前未启用，对我说「开启盘后复盘」即可。" \
    --disabled \
  && echo "market-pulse-postmarket 创建成功 (disabled)" \
  || echo "警告: market-pulse-postmarket 创建失败"
else
  echo "market-pulse-postmarket 已存在，跳过"
fi
set -e

echo ">>> [8/8] 配置定时监控任务 (Crontab)..."
MONITOR_SCRIPT="$OPS_DIR/bootstrap/monitor_updates.sh"
# 日志重定向由脚本内部处理，Crontab 仅负责触发
CRON_JOB="*/5 * * * * $MONITOR_SCRIPT"
(crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" || true; echo "$CRON_JOB") | crontab -

echo "OpenClaw 初始化脚本执行完毕！"
