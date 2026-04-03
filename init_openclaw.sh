#!/bin/bash

# OpenClaw 定制化初始化脚本 (业务独立目录版)
# 执行顺序：环境初始化 -> 预装技能清理 -> 技能部署 -> 插件部署 -> MD资源替换
#          -> 配置写入 -> 服务重启 -> 技能定时任务预配置 -> 定时监控配置

set -e

# --- 业务运维目录配置 ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
ENV_SH="$OPS_DIR/env.sh"

# 加载业务变量与 Node.js 环境 (不依赖 .bashrc)
if [ -f "$ENV_SH" ]; then
    echo ">>> 加载环境配置: $ENV_SH"
    source "$ENV_SH"
fi

LOG_DIR="$OPS_DIR/logs"
SKILLS_CACHE="$OPS_DIR/cache/deepsea-skills"
EXT_CACHE="$OPS_DIR/cache/extensions"
CURRENT_DATE=$(date +%Y%m%d)
LOG_FILE="$LOG_DIR/init_$CURRENT_DATE.log"

# 初始化目录并记录日志
mkdir -p "$LOG_DIR" "$SKILLS_CACHE" "$EXT_CACHE"
exec > >(tee -a "$LOG_FILE") 2>&1

# 进度上报函数
report_step() {
    local step_name=$1
    local token=${WZQ_APIKEY:-$USER_WS_TOKEN}
    if [ -n "$token" ]; then
        echo ">>> [上报进度] $step_name"
        timeout 2s curl -s "https://wzq.tenpay.com/svr/openclaw/agent/report_register_step?token=$token&name=$step_name" > /dev/null || true
    fi
}

echo ">>> [0/10] 开始初始化流程..."

echo ">>> [1/10] 环境变量同步与注入..."
LLM_BASE_URL=${LLM_BASE_URL:-"https://proxy.finance.qq.com/cgi/cgi-bin/openai/sse/openclaw/v1"}
LLM_API_KEY=${WZQ_LLMKEY:-${LLM_API_KEY:-""}}
LLM_PROVIDER_NAME=${LLM_PROVIDER_NAME:-"finance-gateway"}

USER_WS_URL=${USER_WS_URL:-"wss://wzq.tenpay.com/ws/openclaw"}
USER_WS_TOKEN=${WZQ_APIKEY:-${USER_WS_TOKEN:-"user-token-xyz"}}

echo ">>> [2/10] 清理预装技能..."
# 预装技能大部分不需要或使用门槛高，不适合当前业务场景，整体移走备份
BUNDLED_SKILLS_DIR="$HOME/.openclaw/workspace/skills"
BUNDLED_SKILLS_BAK="$HOME/.openclaw/workspace/skills_init"
if [ -d "$BUNDLED_SKILLS_DIR" ]; then
    rm -rf "$BUNDLED_SKILLS_BAK"
    mv "$BUNDLED_SKILLS_DIR" "$BUNDLED_SKILLS_BAK"
    echo "预装技能已移至 $BUNDLED_SKILLS_BAK"
else
    echo "预装技能目录不存在，跳过清理"
fi

echo ">>> [3/10] 拉取并部署深海技能..."
# 环境变量已通过 export 传递给子脚本
# manage_skills.sh 退出码: 0=无变更, 2=有变更(均为成功), 1=出错
set +e
bash "$(dirname "$0")/manage_skills.sh"
SKILL_SYNC_RC=$?
set -e
if [ $SKILL_SYNC_RC -eq 1 ]; then
    echo "警告: 技能同步脚本执行异常，跳过"
fi

report_step "skills_ok"

echo ">>> [4/10] 安装 wzq-channel 插件..."
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
        if command -v jq &>/dev/null; then
            tmp_cfg=$(mktemp)
            jq '.plugins.allow |= (if . then map(select(. != "wzq-channel")) else . end)' "$CLAW_CONFIG" > "$tmp_cfg" && mv "$tmp_cfg" "$CLAW_CONFIG"
        else
            sed -i 's/"wzq-channel"//g; s/,,/,/g; s/\[,/[/g; s/,]/]/g' "$CLAW_CONFIG"
        fi
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

report_step "channel_ok"

echo ">>> [5/10] 下载 wzq-claw-md 资源并替换本地文件..."
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

report_step "md_ok"

echo ">>> [6/10] 写入 openclaw.json 配置 (优先使用 jq 整段替换)..."

# 修改配置的通用函数：优先使用 jq 直接操作文件，失败或无 jq 则回退到 openclaw config
set_openclaw_config_node() {
    local node=$1
    local content=$2
    local config_file="$HOME/.openclaw/openclaw.json"

    if command -v jq &>/dev/null && [ -f "$config_file" ]; then
        if jq ".$node = $content" "$config_file" > "${config_file}.tmp" 2>/dev/null; then
            mv "${config_file}.tmp" "$config_file"
            echo "成功通过 jq 更新节点: $node"
            return 0
        fi
    fi

    # Fallback to openclaw config set
    timeout 15s openclaw config set "$node" "$content" --strict-json
}

# 1. 环境变量 (env)
set_openclaw_config_node "env" '{
  "vars": {
    "WZQ_APIKEY": "'"$WZQ_APIKEY"'"
  }
}'

# 2. 模型配置 (models)
set_openclaw_config_node "models" '{
  "providers": {
    "'"$LLM_PROVIDER_NAME"'": {
      "baseUrl": "'"$LLM_BASE_URL"'",
      "apiKey": "'"$LLM_API_KEY"'",
      "api": "openai-completions",
      "models": [
        {
          "id": "deepsea_minimax_online",
          "name": "deepsea_minimax_online",
          "contextWindow": 128000,
          "maxTokens": 50000,
          "input": ["text"]
        }
      ]
    }
  }
}'

# 3. 代理默认配置 (agents)
set_openclaw_config_node "agents" '{
  "defaults": {
    "model": {
      "primary": "'"$LLM_PROVIDER_NAME"'/deepsea_minimax_online"
    },
    "workspace": "/root/.openclaw/workspace",
    "compaction": {
      "mode": "safeguard"
    },
    "blockStreamingDefault": "on",
    "blockStreamingBreak": "message_end",
    "blockStreamingChunk": {
      "minChars": 800,
      "maxChars": 3500,
      "breakPreference": "paragraph"
    }
  }
}'

# 4. 渠道配置 (channels)
set_openclaw_config_node "channels" '{
  "wzq-channel": {
    "accounts": {
      "default": {
        "enabled": true,
        "token": "'"$USER_WS_TOKEN"'",
        "fileUrl": "https://wzq.tenpay.com/svr/openclaw/agent/get_image",
        "wsUrl": "'"$USER_WS_URL"'"
      }
    }
  }
}'

# 5. 技能配置 (skills)
set_openclaw_config_node "skills" '{
  "allowBundled": ["none"],
  "install": {
    "nodeManager": "npm"
  }
}'

# 6. 插件配置 (plugins)
set_openclaw_config_node "plugins" '{
  "enabled": true,
  "allow": ["wzq-channel"],
  "entries": {
    "wzq-channel": { "enabled": true }
  }
}'

report_step "config_ok"

echo ">>> [7/10] 提升 Operator 权限 (如有必要)..."
DEVICE_AUTH="$HOME/.openclaw/identity/device-auth.json"
PAIRED_JSON="$HOME/.openclaw/devices/paired.json"

if [ -f "$DEVICE_AUTH" ] && [ -f "$PAIRED_JSON" ] && command -v jq &>/dev/null; then
    ROLE=$(jq -r '.tokens.operator.role' "$DEVICE_AUTH" 2>/dev/null)
    if [ "$ROLE" == "operator" ]; then
        echo "检测到 operator 角色，正在提升权限范围..."
        
        # 修改 device-auth.json
        tmp_auth=$(mktemp)
        jq '.tokens.operator.scopes = ["operator.admin", "operator.approvals", "operator.pairing", "operator.read", "operator.write"]' "$DEVICE_AUTH" > "$tmp_auth" && mv "$tmp_auth" "$DEVICE_AUTH"
        
        # 获取 deviceId 并修改 paired.json
        DEVICE_ID=$(jq -r '.deviceId' "$DEVICE_AUTH")
        if [ -n "$DEVICE_ID" ] && [ "$DEVICE_ID" != "null" ]; then
            if jq -e --arg id "$DEVICE_ID" '.[$id] | select(.role == "operator")' "$PAIRED_JSON" >/dev/null 2>&1; then
                tmp_paired=$(mktemp)
                jq --arg id "$DEVICE_ID" '.[$id] |= (
                    .clientId = "cli" | 
                    .clientMode = "cli" | 
                    .scopes = ["operator.read", "operator.admin", "operator.write", "operator.approvals", "operator.pairing"] | 
                    .approvedScopes = ["operator.read", "operator.admin", "operator.write", "operator.approvals", "operator.pairing"] | 
                    .tokens.operator.scopes = ["operator.admin", "operator.approvals", "operator.pairing", "operator.read", "operator.write"]
                )' "$PAIRED_JSON" > "$tmp_paired" && mv "$tmp_paired" "$PAIRED_JSON"
                echo "paired.json 权限提升与模式切换完成 (probe -> cli)"
            fi
        fi
        echo "device-auth.json 权限提升完成"
    else
        echo "role 不是 operator，跳过权限提升 (当前 role: $ROLE)"
    fi
else
    echo "未检测到必要配置文件或 jq 未安装，跳过权限提升"
fi

echo ">>> [8/10] 重启 gateway 服务..."
# 核心修复：确保 NVM/npm link 后的新 PATH 同步到 systemd user 会话，否则 gateway 找不到工具
if command -v systemctl &>/dev/null; then
    systemctl --user import-environment PATH || true
fi
# 确保服务已安装（新版本 OpenClaw 需先执行 install）
timeout 60s openclaw gateway install || true
timeout 60s openclaw gateway restart

report_step "restart_ok"

echo ">>> [9/10] 预配置 skill 定时任务 (disabled)..."
# gateway 启动后才能操作 cron，等待就绪
sleep 10

# --- 股事简报 盘前/盘后定时任务 ---
# 检查是否已存在，避免重复创建；创建为 disabled 状态，用户确认后自行启用
set +e
if ! openclaw cron list --json 2>/dev/null | grep -q "盘前简报"; then
  openclaw cron create \
    --name "盘前简报" \
    --cron "30 8 * * 1-5" \
    --tz "Asia/Shanghai" \
    --session isolated \
    --stagger 30m \
    --message "执行股事简报，进行盘前分析：隔夜要闻、全球行情、资金流向、自选股扫描，生成盘前简报。" \
    --announce \
    --channel wzq-channel \
    --description "A股盘前自选股与市场资讯早报，含隔夜要闻、指数行情、自选股扫描。" \
    --disabled \
  && echo "盘前简报 创建成功 (disabled)" \
  || echo "警告: 盘前简报 创建失败"
else
  echo "盘前简报 已存在，跳过"
fi

if ! openclaw cron list --json 2>/dev/null | grep -q "盘后简报"; then
  openclaw cron create \
    --name "盘后简报" \
    --cron "30 16 * * 1-5" \
    --tz "Asia/Shanghai" \
    --session isolated \
    --stagger 30m \
    --message "执行股事简报，进行盘后复盘：指数收盘、板块涨跌、资金流向、自选股复盘，生成盘后简报。" \
    --announce \
    --channel wzq-channel \
    --description "A股盘后自选股与市场资讯晚报，含板块涨跌、资金流向、自选股复盘。" \
    --disabled \
  && echo "盘后简报 创建成功 (disabled)" \
  || echo "警告: 盘后简报 创建失败"
else
  echo "盘后简报 已存在，跳过"
fi

# --- wzq-implicit-daily-review 每日对话记忆沉淀（静默，凌晨2点） ---
if ! openclaw cron list --json 2>/dev/null | grep -q "wzq-implicit-daily-review"; then
  openclaw cron create \
    --name "wzq-implicit-daily-review" \
    --cron "0 2 * * *" \
    --tz "Asia/Shanghai" \
    --session isolated \
    --stagger 60m \
    --message "执行 wzq-implicit-daily-review skill" \
    --no-deliver \
    --description "每日凌晨静默回顾昨日对话，沉淀用户关注标的到 MEMORY.md。" \
  && echo "wzq-implicit-daily-review 创建成功 (enabled)" \
  || echo "警告: wzq-implicit-daily-review 创建失败"
else
  echo "wzq-implicit-daily-review 已存在，跳过"
fi
set -e

report_step "jobs_ok"

echo ">>> [10/10] 配置定时监控任务 (Crontab)..."
MONITOR_SCRIPT="$OPS_DIR/bootstrap/monitor_updates.sh"
# 日志重定向由脚本内部处理，Crontab 仅负责触发
CRON_JOB="*/5 * * * * $MONITOR_SCRIPT"
(crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" || true; echo "$CRON_JOB") | crontab -

report_step "init_complete"

echo "OpenClaw 初始化脚本执行完毕！"
