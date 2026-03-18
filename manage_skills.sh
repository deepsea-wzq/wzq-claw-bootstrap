#!/bin/bash

# manage_skills.sh
# 职责: 统一管理技能的下载、更新与删除。由 init_openclaw.sh 和 monitor_updates.sh 调用。
# 返回值: 
#   0 - 执行成功，无技能变更
#   2 - 执行成功，有技能变更 (需要重启服务)
#   1 - 执行出错

set -e

# --- 外部变量 (由调用者提供或使用默认值) ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
SKILLS_CACHE_DIR="${SKILLS_CACHE_DIR:-$OPS_DIR/cache/deepsea-skills}"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
SKILLS_DIR="$OPENCLAW_HOME/skills"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-$(dirname "$0")}"
SKILLS_LIST_FILE="$BOOTSTRAP_DIR/skills.list"

# 初始化环境
mkdir -p "$SKILLS_CACHE_DIR" "$SKILLS_DIR"

if [ ! -f "$SKILLS_LIST_FILE" ]; then
    echo "[ManageSkills] 错误: 未找到 $SKILLS_LIST_FILE"
    exit 1
fi

CHANGED=0

# --- 内部工具函数 ---
check_git_update() {
    local dir=$1
    if [ ! -d "$dir" ]; then return 1; fi
    git -C "$dir" fetch --quiet
    LOCAL=$(git -C "$dir" rev-parse @)
    REMOTE=$(git -C "$dir" rev-parse '@{u}')
    [ "$LOCAL" != "$REMOTE" ] && return 0 || return 1
}

deploy_repo_skills() {
    local repo_dir=$1
    local repo_name=$(basename "$repo_dir")
    local old_skills_file=$2  # 可选：旧技能列表文件

    # 1. 同步当前所有技能
    find "$repo_dir" -name "SKILL.md" | while read -r skill_md; do
        skill_src_dir=$(dirname "$skill_md")
        skill_id=$(basename "$skill_src_dir")
        [ "$skill_src_dir" == "$repo_dir" ] && continue
        
        # 覆盖安装
        rm -rf "$SKILLS_DIR/$skill_id"
        cp -r "$skill_src_dir" "$SKILLS_DIR/$skill_id"
    done

    # 2. 如果提供了旧列表，清理已移除的技能
    if [ -n "$old_skills_file" ] && [ -f "$old_skills_file" ]; then
        local new_skills=$(find "$repo_dir" -name "SKILL.md" | xargs -I {} dirname {} | xargs -I {} basename {} 2>/dev/null || true)
        while read -r old_s; do
            [ -z "$old_s" ] && continue
            if ! echo "$new_skills" | grep -qxw "$old_s"; then
                echo "[ManageSkills] 清理仓库 $repo_name 内已删除技能: $old_s"
                rm -rf "$SKILLS_DIR/$old_s"
            fi
        done < "$old_skills_file"
    fi
}

# --- 1. 读取列表与分类 ---
mapfile -t SKILL_REPOS < <(grep -v '^#' "$SKILLS_LIST_FILE" | grep -v '^$')

declare -A ACTIVE_REPOS
for repo in "${SKILL_REPOS[@]}"; do
    if [[ $repo != skillhub:* ]]; then
        repo_name=$(basename "$repo" .git)
        ACTIVE_REPOS["$repo_name"]=1
    fi
done

# --- 2. 清理废弃仓库 ---
for repo_dir in "$SKILLS_CACHE_DIR"/*; do
    [ ! -d "$repo_dir" ] && continue
    repo_name=$(basename "$repo_dir")
    if [ -z "${ACTIVE_REPOS[$repo_name]}" ]; then
        echo "[ManageSkills] 检测到仓库 $repo_name 已移除，正在清理..."
        find "$repo_dir" -name "SKILL.md" | while read -r skill_md; do
            skill_id=$(basename "$(dirname "$skill_md")")
            [ "$skill_id" == "$repo_name" ] && continue
            rm -rf "$SKILLS_DIR/$skill_id"
        done
        rm -rf "$repo_dir"
        CHANGED=1
    fi
done

# --- 3. 同步列表中的仓库 ---
for repo in "${SKILL_REPOS[@]}"; do
    # 3.1 处理 SkillHub 技能
    if [[ $repo == skillhub:* ]]; then
        slug=${repo#skillhub:}
        if command -v skillhub &> /dev/null; then
            # 确保安装。如果已安装，skillhub 通常会提示或静默。
            # 这里我们不追踪 SkillHub 单个技能的“安装导致变更”，因为 SkillHub 有统一 upgrade
            if ! timeout 120s skillhub --dir "$SKILLS_DIR" list | grep -q "$slug"; then
                echo "[ManageSkills] 安装 SkillHub 技能: $slug"
                timeout 120s skillhub --dir "$SKILLS_DIR" install "$slug" &>/dev/null || true
                CHANGED=1
            fi
        fi
        continue
    fi

    # 3.2 处理 Git 仓库
    repo_name=$(basename "$repo" .git)
    local_cache="$SKILLS_CACHE_DIR/$repo_name"

    # 特殊处理 wzq-skills 的私有令牌
    current_repo_url="$repo"
    if [[ "$repo_name" == "wzq-skills" ]]; then
        if [ -n "$WZQ_SKILLS_TOKEN" ]; then
            # 注入私有令牌，支持 x492876854 账号。如果 token 已包含在 repo URL 中，则跳过注入。
            if [[ "$repo" != *"@"* ]]; then
                current_repo_url="${repo/https:\/\/github.com\//https:\/\/x492876854:${WZQ_SKILLS_TOKEN}@github.com\/}"
                echo "[ManageSkills] 环境变量检测到令牌，尝试私有访问 $repo_name"
            fi
        else
            echo "[ManageSkills] 未检测到令牌，尝试使用原链接直接访问 $repo_name"
        fi
    fi

    if [ ! -d "$local_cache" ]; then
        echo "[ManageSkills] 克隆新仓库: $repo_name"
        timeout 60s git clone --quiet --depth 1 "$current_repo_url" "$local_cache" &>/dev/null || { echo "[ManageSkills] 克隆 $repo_name 失败"; continue; }
        deploy_repo_skills "$local_cache"
        CHANGED=1
    else
        # 检查并更新
        # 针对 wzq-skills，始终同步远程地址以反映当前环境变量状态（令牌可能增加或移除）
        if [[ "$repo_name" == "wzq-skills" ]]; then
             git -C "$local_cache" remote set-url origin "$current_repo_url"
        fi

        if check_git_update "$local_cache"; then
            echo "[ManageSkills] 更新仓库: $repo_name"
            # 记录更新前的技能列表
            OLD_SKILLS_FILE=$(mktemp)
            find "$local_cache" -name "SKILL.md" | xargs -I {} dirname {} | xargs -I {} basename {} 2>/dev/null > "$OLD_SKILLS_FILE" || true
            
            git -C "$local_cache" pull --quiet
            deploy_repo_skills "$local_cache" "$OLD_SKILLS_FILE"
            rm -f "$OLD_SKILLS_FILE"
            CHANGED=1
        fi
    fi
done

# --- 4. 统一执行 SkillHub Upgrade ---
if command -v skillhub &> /dev/null; then
    # 注意: skillhub upgrade 可能会升级已安装的所有技能。
    # 我们这里默认执行，如果有实际变更，SkillHub 输出会有体现，但目前我们无法精确捕获其“变更”状态。
    # 为了保险，只要执行了 upgrade，如果在 monitor 中，可以考虑不强制 NEED_RESTART，除非用户有更细的要求。
    # 这里我们认为 upgrade 是例行检查。
    timeout 120s skillhub --dir "$SKILLS_DIR" upgrade &>/dev/null || true
fi

# --- 5. 返回状态 ---
if [ $CHANGED -eq 1 ]; then
    echo "[ManageSkills] 同步完成，有变更。"
    exit 2
else
    echo "[ManageSkills] 同步完成，无变更。"
    exit 0
fi
