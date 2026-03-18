#!/bin/bash

# OpenClaw 监控与自动更新脚本 (业务独立目录版)
# 职责：检查插件和技能仓库更新 -> 触发重启

# --- 业务目录配置 ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
BOOTSTRAP_DIR="$OPS_DIR/bootstrap"
LOG_DIR="$OPS_DIR/logs"
SKILLS_CACHE_DIR="$OPS_DIR/cache/deepsea-skills"
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

# --- 0. 脚本自更新机制 ---
if [ -d "$BOOTSTRAP_DIR/.git" ]; then
    if check_git_update "$BOOTSTRAP_DIR"; then
        echo "检测到 bootstrap 脚本自身更新，正在同步..."
        git -C "$BOOTSTRAP_DIR" pull
        chmod +x "$BOOTSTRAP_DIR"/*.sh
        echo "脚本已更新，正在重启自身以应用最新逻辑..."
        exec "$0" "$@"
    fi
fi

OPENCLAW_HOME="$HOME/.openclaw"
EXT_DIR="$OPENCLAW_HOME/extensions/wzq-channel"
NEED_RESTART=0

# 1. 检查 wzq-channel 插件更新
if check_git_update "$EXT_DIR"; then
    echo "检测到插件 wzq-channel 更新，正在拉取并安装依赖..."
    git -C "$EXT_DIR" pull
    cd "$EXT_DIR"
    pnpm install --prod || npm install --prod
    NEED_RESTART=1
fi

# 2. 检查技能仓库缓存更新
if [ -d "$SKILLS_CACHE_DIR" ]; then
    for repo_dir in "$SKILLS_CACHE_DIR"/*; do
        if [ -d "$repo_dir/.git" ]; then
            if check_git_update "$repo_dir"; then
                echo "检测到技能仓库 $(basename "$repo_dir") 更新，正在拉取并重新部署..."
                git -C "$repo_dir" pull
                
                # 分发该仓库下的所有技能
                find "$repo_dir" -name "SKILL.md" | while read -r skill_md; do
                    skill_src_dir=$(dirname "$skill_md")
                    skill_id=$(basename "$skill_src_dir")
                    [ "$skill_src_dir" == "$repo_dir" ] && continue
                    
                    echo "同步技能: $skill_id"
                    rm -rf "$OPENCLAW_HOME/skills/$skill_id"
                    cp -r "$skill_src_dir" "$OPENCLAW_HOME/skills/$skill_id"
                done

                NEED_RESTART=1
            fi
        fi
    done
fi

# 3. 如果有更新，执行重启
if [ $NEED_RESTART -eq 1 ]; then
    echo "执行服务重启以应用更新..."
    openclaw gateway install || true
    openclaw gateway restart
    echo "更新处理完成。"
else
    echo "未发现更新。"
fi
