#!/bin/bash

# OpenClaw 监控与自动更新脚本 (业务独立目录版)
# 职责：检查插件、技能仓库及运维代码更新 -> 自动同步并重启

# --- 业务目录配置 ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
BOOTSTRAP_DIR="$OPS_DIR/bootstrap"
LOG_DIR="$OPS_DIR/logs"
SKILLS_CACHE_DIR="$OPS_DIR/cache/deepsea-skills"
EXT_CACHE_DIR="$OPS_DIR/cache/extensions"
OPENCLAW_HOME="$HOME/.openclaw"
CURRENT_DATE=$(date +%Y%m%d)
LOG_FILE="$LOG_DIR/monitor_$CURRENT_DATE.log"

# 初始化日志记录
mkdir -p "$LOG_DIR"
exec >> "$LOG_FILE" 2>&1

echo "--- $(date '+%Y-%m-%d %H:%M:%S') 开始检查更新 ---"

# --- 通用工具函数 ---
check_git_update() {
    local dir=$1
    if [ ! -d "$dir" ]; then return 1; fi
    
    git -C "$dir" fetch --quiet
    LOCAL=$(git -C "$dir" rev-parse @)
    REMOTE=$(git -C "$dir" rev-parse '@{u}')
    
    if [ "$LOCAL" != "$REMOTE" ]; then
        return 0 # 有更新
    else
        return 1 # 无更新
    fi
}

NEED_RESTART=0

# --- 0. 脚本自更新机制 (运维代码变更) ---
if check_git_update "$BOOTSTRAP_DIR"; then
    echo "检测到运维脚本更新, 正在执行自更新及重新初始化..."
    git -C "$BOOTSTRAP_DIR" pull --quiet
    # 自更新后执行初始化脚本以应用可能的 SKILL_REPOS 变更
    bash "$BOOTSTRAP_DIR/init_openclaw.sh"
    echo "自更新完成。"
    exit 0 # init_openclaw 会处理重启逻辑，此处直接退出
fi

# --- 1. 检查 wzq-channel 插件更新 ---
EXT_DIR="$EXT_CACHE_DIR/wzq-channel"
if [ -d "$EXT_DIR/.git" ]; then
    if check_git_update "$EXT_DIR"; then
        echo "检测到插件 wzq-channel 更新, 正在拉取并重新安装..."
        git -C "$EXT_DIR" pull --quiet
        
        # 增量处理可能存在的死锁（仅清理 wzq-channel）
        CURRENT_ALLOW=$(openclaw config get "plugins.allow" 2>/dev/null || echo "[]")
        if [[ $CURRENT_ALLOW == *"wzq-channel"* ]]; then
             CLEAN_ALLOW=$(echo "$CURRENT_ALLOW" | sed 's/"wzq-channel"//g; s/,,/,/g; s/\[,/[/g; s/,]/]/g')
             openclaw config set "plugins.allow" "$CLEAN_ALLOW" --strict-json || true
        fi
        
        rm -rf "$OPENCLAW_HOME/extensions/wzq-channel"
        openclaw plugins install "$EXT_DIR"
        
        # 补齐配置：增量启用插件并加入信任名单
        openclaw config set "plugins.enabled" true
        openclaw config set "plugins.entries.wzq-channel.enabled" true
        
        CURRENT_ALLOW=$(openclaw config get "plugins.allow" 2>/dev/null || echo "[]")
        if [[ $CURRENT_ALLOW != *"wzq-channel"* ]]; then
            if [ "$CURRENT_ALLOW" == "[]" ] || [ -z "$CURRENT_ALLOW" ]; then
                openclaw config set "plugins.allow" "[\"wzq-channel\"]" --strict-json
            else
                NEW_ALLOW="${CURRENT_ALLOW%]*},\"wzq-channel\"]"
                openclaw config set "plugins.allow" "$NEW_ALLOW" --strict-json
            fi
        fi
        
        NEED_RESTART=1
    fi
fi

# --- 2. 检查技能仓库更新与同步 (调用管理脚本) ---
set +e # 临时关闭，以便手动检查 exit code
bash "$BOOTSTRAP_DIR/manage_skills.sh"
SKILL_SYNC_RC=$?
set -e

if [ $SKILL_SYNC_RC -eq 2 ]; then
    NEED_RESTART=1
fi

# --- 4. 如果有更新，执行重启 ---
if [ $NEED_RESTART -eq 1 ]; then
    echo "执行服务重启以应用更新..."
    openclaw gateway restart
    echo "更新处理完成。"
else
    echo "未发现更新。"
fi
