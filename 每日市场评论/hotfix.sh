#!/bin/bash

# ============================================
# DangInvest 轻量热更新脚本
# 用法:
#   ./hotfix.sh articles   # 仅更新文章（不停服）
#   ./hotfix.sh frontend   # 前端蓝绿发布（尽量不停服）
#   ./hotfix.sh            # 自动检测变更类型
# 可选:
#   HOTFIX_RUN_SIMILARITIES=true  # 文章更新后额外计算相似度（较慢）
#   HOTFIX_PRUNE_IMAGES=false     # 禁用 dangling image 清理（便于回滚）
#   HOTFIX_STOP_OLD=false         # 切流后不 stop 旧版本（短期回滚窗口；注意重复 scheduler 风险）
#   HOTFIX_ROLLBACK_WINDOW_SEC=3600 # 切流后保留旧版本 N 秒再 stop（回滚窗口；建议搭配蓝绿 scheduler 互斥）
# ============================================

set -Eeuo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

trap 'echo -e "${RED}Error: command failed (line ${LINENO}): ${BASH_COMMAND}${NC}" >&2' ERR

# ============================================
# 辅助函数
# ============================================
die() {
    echo -e "${RED}Error: $*${NC}" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}$*${NC}" >&2
}

info() {
    echo -e "${GREEN}$*${NC}"
}

get_active_frontend_color() {
    local state_dir="${SCRIPT_DIR}/deploy-state"
    local active_file="${state_dir}/frontend_active"
    mkdir -p "${state_dir}"

    local color
    color="$(cat "${active_file}" 2>/dev/null | tr -d ' \r\n\t' || true)"
    if [ "${color}" = "blue" ] || [ "${color}" = "green" ]; then
        echo "${color}"
        return 0
    fi

    # 兜底：从当前 nginx.generated.conf 推断 liveColor
    local detected=""
    if [ -f "${SCRIPT_DIR}/nginx/nginx.generated.conf" ]; then
        detected="$(grep -Eo 'server[[:space:]]+frontend-(blue|green):3000' "${SCRIPT_DIR}/nginx/nginx.generated.conf" | head -1 | sed -E 's/.*frontend-(blue|green):3000.*/\\1/' || true)"
    fi
    if [ "${detected}" != "blue" ] && [ "${detected}" != "green" ]; then
        detected="blue"
    fi

    echo "${detected}" > "${active_file}"
    echo "${detected}"
}

set_frontend_context() {
    ACTIVE_COLOR="$(get_active_frontend_color)"
    if [ "${ACTIVE_COLOR}" = "blue" ]; then
        INACTIVE_COLOR="green"
    else
        INACTIVE_COLOR="blue"
    fi

    ACTIVE_FRONTEND_SERVICE="frontend-${ACTIVE_COLOR}"
    INACTIVE_FRONTEND_SERVICE="frontend-${INACTIVE_COLOR}"
    ACTIVE_FRONTEND_CONTAINER="danginvest-frontend-${ACTIVE_COLOR}"
    INACTIVE_FRONTEND_CONTAINER="danginvest-frontend-${INACTIVE_COLOR}"
}

preflight() {
    # 基本依赖检查（对齐 deploy.sh 的谨慎程度）
    command -v docker >/dev/null 2>&1 || die "Docker is not installed"
    docker compose version >/dev/null 2>&1 || die "Docker Compose is not available"
    docker info >/dev/null 2>&1 || die "Docker daemon is not running"

    # 磁盘空间检查（避免 build/cp 过程中爆盘）
    if command -v df >/dev/null 2>&1; then
        local disk_usage
        local disk_avail
        disk_usage="$(df / | tail -1 | awk '{print $5}' | sed 's/%//')"
        disk_avail="$(df -h / | tail -1 | awk '{print $4}')"
        echo -e "Disk available: ${disk_avail:-unknown} (${disk_usage:-unknown}% used)"
        if [ -n "${disk_usage:-}" ] && [ "${disk_usage}" -gt 90 ]; then
            die "Disk usage is above 90%. Please free up space before running hotfix."
        elif [ -n "${disk_usage:-}" ] && [ "${disk_usage}" -gt 80 ]; then
            warn "Warning: Disk usage is above 80%. Consider freeing up space."
        fi
    fi

    # .env 由 Docker Compose 自动加载（无需 source；避免 .env 非 bash 语法导致隐患）
    if [ ! -f .env ]; then
        warn "Warning: .env not found in ${SCRIPT_DIR}. docker compose substitution may use defaults or fail."
    fi
}

ensure_submodules() {
    if [ ! -f .gitmodules ]; then
        return 0
    fi

    command -v git >/dev/null 2>&1 || die "git is required (repo uses submodules via .gitmodules)"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git repository. Submodules cannot be updated."

    # 先 sync，再 update：避免 .git/config 里残留旧 url（例如本机 path）导致生产机拉取失败
    info "Syncing git submodule URLs..."
    git submodule sync --recursive >/dev/null 2>&1 || true

    info "Updating git submodules (init + checkout pinned commits)..."
    if ! git submodule update --init --recursive; then
        echo -e "${RED}Error: failed to update git submodules.${NC}" >&2
        echo -e "${YELLOW}Hints:${NC}" >&2
        echo -e "${YELLOW}  - Ensure this repo was cloned via git (not copied) and you have access to submodule remotes.${NC}" >&2
        echo -e "${YELLOW}  - If using GitHub HTTPS for private repos, configure a token/credential helper or switch submodule URLs to SSH.${NC}" >&2
        echo -e "${YELLOW}  - Run: git submodule sync --recursive && git submodule update --init --recursive${NC}" >&2
        exit 1
    fi

    local status
    status="$(git submodule status --recursive 2>/dev/null || true)"
    if echo "${status}" | grep -qE '^-|^\+|^U'; then
        echo -e "${RED}Error: submodule state is not clean after update.${NC}" >&2
        echo -e "${YELLOW}${status}${NC}" >&2
        exit 1
    fi

    # fail-fast：确保关键子模块路径已实际落盘（避免 docker build/cp 半途才报错）
    local required_paths=()
    while IFS= read -r sub_path; do
        [ -z "${sub_path}" ] && continue
        required_paths+=("${sub_path}")
    done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')

    local missing=()
    for p in "${required_paths[@]:-}"; do
        if [ ! -e "${p}" ]; then
            missing+=("${p}")
            continue
        fi
        # 子模块目录应当包含 .git（gitfile 或目录）；否则大概率是未初始化/被覆盖
        if [ -d "${p}" ] && [ ! -e "${p}/.git" ]; then
            missing+=("${p}")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo -e "${RED}Error: required submodule paths are missing or not initialized:${NC} ${missing[*]}" >&2
        echo -e "${YELLOW}Run: git submodule update --init --recursive${NC}" >&2
        exit 1
    fi
}

check_service_running() {
    local service=$1
    docker compose ps "$service" 2>/dev/null | grep -qE "Up|running"
}

ensure_frontend_writable() {
    set_frontend_context

    # docker cp 可能会把文件 UID/GID 变成宿主机的数值（常见是 root:root），导致容器内 nextjs 用户无法写入
    # 这里用 root 修复权限，确保 OCR / scan / index / embed 能正常写入：
    # - /app/dang_articles（.ocr.md、frontmatter 更新）
    # - /app/cache（索引文件）
    # - /app/public/article-assets（静态资源同步）
    if docker exec "${ACTIVE_FRONTEND_CONTAINER}" sh -lc "test -w /app/dang_articles && test -w /app/cache && test -w /app/public/article-assets" >/dev/null 2>&1; then
        return 0
    fi

    warn "Fixing frontend container permissions..."
    docker exec -u 0 "${ACTIVE_FRONTEND_CONTAINER}" sh -lc "mkdir -p /app/public/article-assets && chown -R nextjs:nodejs /app/dang_articles /app/cache /app/public/article-assets" >/dev/null
}

cleanup_deleted_articles_in_container() {
    local diff_base=$1
    set_frontend_context

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi

    local deleted=""

    # dang_articles 已切为 submodule 后，superproject 的 diff 只会出现 gitlink（dang_articles），
    # 无法直接列出子模块内被删除/重命名的具体文件。
    # 这里通过“子模块旧 commit → 新 commit”的 diff 推断要清理的旧路径，避免容器内残留 ghost articles。
    local is_articles_submodule="false"
    if [ -f .gitmodules ]; then
        if git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}' | grep -qx 'dang_articles'; then
            is_articles_submodule="true"
        fi
    fi

    if [ "${is_articles_submodule}" = "true" ]; then
        local old_sha=""
        local new_sha=""
        old_sha="$(git ls-tree "${diff_base}" dang_articles 2>/dev/null | awk '{print $3}' | head -1 || true)"
        new_sha="$(git ls-tree HEAD dang_articles 2>/dev/null | awk '{print $3}' | head -1 || true)"

        if [ -n "${old_sha}" ] && [ -n "${new_sha}" ] && [ "${old_sha}" != "${new_sha}" ]; then
            deleted="$(
                git -C dang_articles diff --name-status --diff-filter=DR "${old_sha}" "${new_sha}" 2>/dev/null \
                    | awk -F '\t' '$1 ~ /^D/ {print "dang_articles/" $2} $1 ~ /^R/ {print "dang_articles/" $2}' \
                    | sed '/^dang_articles\/$/d' \
                    || true
            )"
        fi
    fi

    if [ -z "${deleted}" ]; then
        deleted="$(git diff --name-only --diff-filter=D "${diff_base}" HEAD -- dang_articles/ 2>/dev/null || true)"
    fi
    if [ -z "${deleted}" ]; then
        return 0
    fi

    warn "Detected deleted files under dang_articles/; removing from frontend container to avoid stale/ghost articles..."
    while IFS= read -r rel; do
        [ -z "${rel}" ] && continue
        # 安全护栏：只允许删 dang_articles/ 下的路径
        if ! echo "${rel}" | grep -qE '^dang_articles/'; then
            continue
        fi
        # 如果本地仍存在该文件（例如工作区未提交/重新生成），不要删除容器内副本
        if [ -e "${SCRIPT_DIR}/${rel}" ]; then
            continue
        fi
        docker exec -u 0 "${ACTIVE_FRONTEND_CONTAINER}" rm -f "/app/${rel}" 2>/dev/null || true
    done <<< "${deleted}"
}

# 清除 Redis 缓存（按 pattern 列表）
# 用法: clear_redis_cache "articles:*" "search:*" "graph:*"
clear_redis_cache() {
    if ! check_service_running redis; then
        warn "Redis not running, skipping cache clear"
        return
    fi
    if ! docker exec danginvest-redis redis-cli ping >/dev/null 2>&1; then
        warn "Redis ping failed, skipping cache clear"
        return
    fi

    # 生产环境避免使用 KEYS（可能阻塞 Redis）；改用 SCAN + UNLINK（异步删除）
    for pattern in "$@"; do
        docker exec danginvest-redis sh -lc "redis-cli --scan --pattern '${pattern}' | xargs -r -n 500 redis-cli UNLINK >/dev/null" 2>/dev/null || true
        echo -e "  Cleared ${pattern}"
    done
}

# ============================================
# 仅更新文章（不停服）
# dang_articles 通过 volume 挂载到 nginx，但 frontend 容器内是
# 构建时 COPY 的副本。需要用 docker cp 同步到容器内。
# ============================================
update_articles() {
    local diff_base="${1:-}"

    info "=== Updating articles (no downtime) ==="

    set_frontend_context

    if ! check_service_running "${ACTIVE_FRONTEND_SERVICE}"; then
        die "Frontend container is not running (${ACTIVE_FRONTEND_SERVICE})"
    fi

    # 手动模式下也尽量推断 diff_base，用于清理容器内已删除的旧文章文件
    if [ -z "${diff_base}" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if git rev-parse ORIG_HEAD &>/dev/null; then
            diff_base="ORIG_HEAD"
        elif git rev-parse 'HEAD@{1}' &>/dev/null; then
            diff_base='HEAD@{1}'
        fi
    fi

    # 同步文章到 frontend 容器（容器内是构建时 COPY 的，宿主机更新后需要同步）
    info "Syncing articles to frontend container..."
    docker cp "$SCRIPT_DIR/dang_articles/." "${ACTIVE_FRONTEND_CONTAINER}":/app/dang_articles/

    # 删除/重命名的文件不会被 docker cp 同步删除；auto 模式下用 diff_base 补做清理
    if [ -n "${diff_base}" ]; then
        cleanup_deleted_articles_in_container "${diff_base}"
    fi

    ensure_frontend_writable

    # OCR 图片识别（新文章可能包含图片）
    info "Running OCR image recognition..."
    docker exec "${ACTIVE_FRONTEND_CONTAINER}" node scripts/run-ocr-images.js 2>&1 || warn "Warning: OCR failed, will retry on next restart"

    # 股票别名扫描（新文章可能引用股票）
    info "Running stock alias scan..."
    docker exec "${ACTIVE_FRONTEND_CONTAINER}" node scripts/scan-stocks.js 2>&1 || warn "Warning: Stock scan failed, will retry on next restart"

    # 增量更新向量嵌入（对齐 embed-scheduler：默认双 provider）
    info "Updating article embeddings (incremental)..."
    docker exec "${ACTIVE_FRONTEND_CONTAINER}" node scripts/run-embed-articles.js --provider both 2>&1 || warn "Warning: Embedding update failed, articles still accessible"

    # （可选）更新文章相似度：默认关闭（可能较慢）；可通过 HOTFIX_RUN_SIMILARITIES=true 打开
    local run_sim="${HOTFIX_RUN_SIMILARITIES:-false}"
    if [ "${run_sim}" = "true" ] || [ "${run_sim}" = "1" ]; then
        info "Computing article similarities..."
        docker exec "${ACTIVE_FRONTEND_CONTAINER}" node scripts/run-compute-article-similarities.js 2>&1 || warn "Warning: Similarity compute failed, will retry on next scheduler run"
    else
        echo -e "${YELLOW}Skipping similarity computation (set HOTFIX_RUN_SIMILARITIES=true to enable)${NC}"
    fi

    # 重建搜索索引和知识图谱（含静态资源同步/图谱语义边加载）
    info "Rebuilding article index (search/graph/metadata)..."
    docker exec "${ACTIVE_FRONTEND_CONTAINER}" node scripts/run-build-article-index.js

    # 清除文章相关缓存
    info "Clearing article caches..."
    clear_redis_cache "articles:*" "article:*" "search:*" "graph:*"

    # 更新 Changelog
    if [ -f "${SCRIPT_DIR}/CHANGELOG.md" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        info "Updating changelog..."
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        local temp_changelog
        temp_changelog="$(mktemp)"

        # 生成 changelog 条目
        {
            echo ""
            echo "## [Hotfix - Articles Update] - ${timestamp}"
            echo ""

            # 获取变更信息
            if [ -n "${diff_base}" ]; then
                local commits
                commits="$(git log --oneline --no-decorate "${diff_base}..HEAD" 2>/dev/null || true)"
                if [ -n "${commits}" ]; then
                    echo "### Changes"
                    echo '```'
                    echo "${commits}"
                    echo '```'
                    echo ""
                fi

                # 变更文件列表
                local changed_files
                changed_files="$(git diff --name-only "${diff_base}" HEAD -- dang_articles/ 2>/dev/null | head -20 || true)"
                if [ -n "${changed_files}" ]; then
                    echo "### Changed Files"
                    echo '```'
                    echo "${changed_files}"
                    local total
                    total="$(git diff --name-only "${diff_base}" HEAD -- dang_articles/ 2>/dev/null | wc -l || echo 0)"
                    if [ "${total}" -gt 20 ]; then
                        echo "... and $((total - 20)) more files"
                    fi
                    echo '```'
                    echo ""
                fi
            fi

            echo "### Deployment Info"
            echo "- Type: hotfix (articles)"
            echo "- Time: ${timestamp}"
            echo "- Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
            echo "- Commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
            echo ""
            echo "---"
        } > "${temp_changelog}"

        # 在 "---" 分隔符后插入新条目
        awk -v entry="$(cat "${temp_changelog}")" '
            /^---$/ && !inserted {
                print $0
                print entry
                inserted=1
                next
            }
            { print }
        ' "${SCRIPT_DIR}/CHANGELOG.md" > "${temp_changelog}.new"

        mv "${temp_changelog}.new" "${SCRIPT_DIR}/CHANGELOG.md"
        rm -f "${temp_changelog}"

        info "Changelog updated"
    fi

    info "Articles updated successfully!"
}

# ============================================
# 仅重建前端（短暂重启）
# entrypoint.sh 启动时会自动执行 OCR、股票扫描、索引构建、缓存清理，
# 所以这里只需要构建镜像、重启容器、等待就绪。
# ============================================
update_frontend() {
    info "=== Frontend blue/green deploy (no downtime) ==="

    set_frontend_context

    info "Active: ${ACTIVE_FRONTEND_SERVICE}"
    info "Target: ${INACTIVE_FRONTEND_SERVICE}"

    # 0) 确保 nginx 在线（用于切流与兜底维护页）
    docker compose up -d --no-deps nginx >/dev/null 2>&1 || true
    if ! check_service_running nginx; then
        die "nginx is not running; cannot switch traffic safely (docker compose ps nginx)"
    fi

    # 1) 构建 target 镜像（不影响 active）
    info "Building target frontend image..."
    docker compose build "${INACTIVE_FRONTEND_SERVICE}"

    # 2) 启动 target 容器（不影响 active）
    info "Starting target frontend..."
    docker compose up -d --no-deps --force-recreate "${INACTIVE_FRONTEND_SERVICE}"

    # 3) 等待 target /api/ready（容器内自检，避免依赖 wget/curl）
    info "Waiting for target /api/ready..."
    READY=false
    for i in {1..240}; do
        if docker exec "${INACTIVE_FRONTEND_CONTAINER}" node -e "fetch('http://127.0.0.1:3000/api/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
            READY=true
            break
        fi
        echo "  not ready yet ($i/240)"
        sleep 2
    done
    if [ "$READY" != "true" ]; then
        die "Target frontend failed to become healthy in time. Check logs: docker compose logs -f ${INACTIVE_FRONTEND_SERVICE}"
    fi

    # 4) 切流：生成 nginx 配置 → nginx -t → reload
    info "Switching traffic to target..."
    export FRONTEND_SERVICE="${INACTIVE_FRONTEND_SERVICE}"
    ./scripts/gen-nginx-conf.sh
    docker compose exec -T nginx nginx -t
    docker compose exec -T nginx nginx -s reload

    # 5) 记录 active color（切流完成后立即写入，避免“切流已发生但 state 还指向旧版本”的不一致）
    mkdir -p "${SCRIPT_DIR}/deploy-state"
    echo "${INACTIVE_COLOR}" > "${SCRIPT_DIR}/deploy-state/frontend_active"

    # 6) （可选）保留旧版本作为回滚窗口
    # 默认仍然 stop old，避免资源占用与后台任务重复（如需更长窗口，建议启用 scheduler 互斥/leader 机制）。
    local stop_old="${HOTFIX_STOP_OLD:-true}"
    local rollback_window_sec="${HOTFIX_ROLLBACK_WINDOW_SEC:-0}"
    if [ "${stop_old}" = "false" ] || [ "${stop_old}" = "0" ]; then
        warn "Keeping old frontend running (HOTFIX_STOP_OLD=false). Remember to stop it after verification:"
        warn "  docker compose stop ${ACTIVE_FRONTEND_SERVICE}"
    else
        if [ -n "${rollback_window_sec}" ] && [[ "${rollback_window_sec}" =~ ^[0-9]+$ ]] && [ "${rollback_window_sec}" -gt 0 ]; then
            warn "Keeping old frontend running for rollback window: ${rollback_window_sec}s"
            # 不阻塞当前发布脚本：后台定时 stop old，但会先检查 active 是否仍然是新版本，
            # 避免“窗口内发生回滚/再次切流”导致误停当前 active。
            mkdir -p "${SCRIPT_DIR}/deploy-state"
            local ts
            ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo 'now')"
            local stop_log="${SCRIPT_DIR}/deploy-state/hotfix-stop-old.${ACTIVE_COLOR}.to.${INACTIVE_COLOR}.${ts}.log"
            nohup bash -lc "set -Eeuo pipefail; cd '${SCRIPT_DIR}'; echo \"[\\$(date '+%Y-%m-%d %H:%M:%S')] scheduled: stop ${ACTIVE_FRONTEND_SERVICE} after ${rollback_window_sec}s (expected active=${INACTIVE_COLOR})\"; sleep '${rollback_window_sec}'; active=\\$(cat '${SCRIPT_DIR}/deploy-state/frontend_active' 2>/dev/null | tr -d ' \\r\\n\\t' || true); if [ \"\\$active\" != '${INACTIVE_COLOR}' ]; then echo \"[\\$(date '+%Y-%m-%d %H:%M:%S')] skip: active=\\$active\"; exit 0; fi; echo \"[\\$(date '+%Y-%m-%d %H:%M:%S')] stopping ${ACTIVE_FRONTEND_SERVICE}...\"; docker compose stop '${ACTIVE_FRONTEND_SERVICE}' >/dev/null 2>&1 || true; echo \"[\\$(date '+%Y-%m-%d %H:%M:%S')] done\";" > "${stop_log}" 2>&1 &
            warn "Scheduled stop-old task in background:"
            warn "  log: ${stop_log}"
        else
            info "Stopping old frontend..."
            docker compose stop "${ACTIVE_FRONTEND_SERVICE}" >/dev/null 2>&1 || true
        fi
    fi

    # 清理悬空镜像（可选，便于回滚可关）
    local prune_images="${HOTFIX_PRUNE_IMAGES:-true}"
    if [ "${prune_images}" = "true" ] || [ "${prune_images}" = "1" ]; then
        docker image prune -f 2>/dev/null || true
    else
        warn "Skipping dangling image prune (HOTFIX_PRUNE_IMAGES=false)"
    fi

    # 更新 Changelog
    if [ -f "${SCRIPT_DIR}/CHANGELOG.md" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        info "Updating changelog..."
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        local temp_changelog
        temp_changelog="$(mktemp)"

        # 生成 changelog 条目
        {
            echo ""
            echo "## [Hotfix - Frontend Update] - ${timestamp}"
            echo ""

            # 获取变更信息
            local diff_base=""
            if git rev-parse ORIG_HEAD &>/dev/null; then
                diff_base="ORIG_HEAD"
            elif git rev-parse 'HEAD@{1}' &>/dev/null; then
                diff_base='HEAD@{1}'
            fi

            if [ -n "${diff_base}" ]; then
                local commits
                commits="$(git log --oneline --no-decorate "${diff_base}..HEAD" 2>/dev/null || true)"
                if [ -n "${commits}" ]; then
                    echo "### Changes"
                    echo '```'
                    echo "${commits}"
                    echo '```'
                    echo ""
                fi

                # 变更文件列表
                local changed_files
                changed_files="$(git diff --name-only "${diff_base}" HEAD 2>/dev/null | head -20 || true)"
                if [ -n "${changed_files}" ]; then
                    echo "### Changed Files"
                    echo '```'
                    echo "${changed_files}"
                    local total
                    total="$(git diff --name-only "${diff_base}" HEAD 2>/dev/null | wc -l || echo 0)"
                    if [ "${total}" -gt 20 ]; then
                        echo "... and $((total - 20)) more files"
                    fi
                    echo '```'
                    echo ""
                fi
            fi

            echo "### Deployment Info"
            echo "- Type: hotfix (frontend)"
            echo "- Time: ${timestamp}"
            echo "- Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
            echo "- Commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
            echo "- Blue/Green: ${ACTIVE_COLOR} → ${INACTIVE_COLOR}"
            echo ""
            echo "---"
        } > "${temp_changelog}"

        # 在 "---" 分隔符后插入新条目
        awk -v entry="$(cat "${temp_changelog}")" '
            /^---$/ && !inserted {
                print $0
                print entry
                inserted=1
                next
            }
            { print }
        ' "${SCRIPT_DIR}/CHANGELOG.md" > "${temp_changelog}.new"

        mv "${temp_changelog}.new" "${SCRIPT_DIR}/CHANGELOG.md"
        rm -f "${temp_changelog}"

        info "Changelog updated"
    fi

    info "Frontend switched successfully! Active is now: frontend-${INACTIVE_COLOR}"
}

# ============================================
# 自动检测变更类型
# 使用 ORIG_HEAD（git pull/merge 自动设置）比 HEAD@{1} 更可靠
# ============================================
auto_detect() {
    info "Auto-detecting changes..."

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "Not a git repository. Please specify: ./hotfix.sh [articles|frontend]"
    fi

    # ORIG_HEAD 由 git pull/merge/rebase 自动设置，指向操作前的 HEAD
    local diff_base=""
    if git rev-parse ORIG_HEAD &>/dev/null; then
        diff_base="ORIG_HEAD"
    else
        # 兜底：尝试使用 reflog（可能不如 ORIG_HEAD 精准）
        if git rev-parse 'HEAD@{1}' &>/dev/null; then
            diff_base='HEAD@{1}'
            warn "ORIG_HEAD not found; falling back to HEAD@{1} for diff base."
        else
            die "ORIG_HEAD not found (no recent git pull?) and HEAD@{1} unavailable. Please specify: ./hotfix.sh [articles|frontend]"
        fi
    fi

    local changed_committed
    changed_committed="$(git diff --name-only "${diff_base}" HEAD 2>/dev/null || true)"

    # 额外包含工作区未提交变更（避免 auto 模式漏检）
    local changed_worktree=""
    if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
        warn "Working tree is not clean; including unstaged/staged changes in detection."
        changed_worktree="$(
            {
                git diff --name-only 2>/dev/null || true
                git diff --name-only --cached 2>/dev/null || true
                git ls-files --others --exclude-standard 2>/dev/null || true
            } | sort -u
        )"
    fi

    CHANGED_FILES="$(
        {
            echo "${changed_committed}"
            echo "${changed_worktree}"
        } | sed '/^$/d' | sort -u
    )"

    if [ -z "$CHANGED_FILES" ]; then
        die "No changes detected. Please specify: ./hotfix.sh [articles|frontend]"
    fi

    echo -e "Changed files:"
    echo "$CHANGED_FILES" | head -20
    TOTAL=$(echo "$CHANGED_FILES" | wc -l)
    if [ "$TOTAL" -gt 20 ]; then
        echo -e "  ... and $((TOTAL - 20)) more"
    fi
    echo ""

    HAS_ARTICLES=false
    HAS_FRONTEND=false

    if echo "$CHANGED_FILES" | grep -qE "^src/|^public/|^scripts/|^next\\.config|^tailwind|^package\\.json|^package-lock\\.json|^Dockerfile$|^entrypoint\\.sh$"; then
        HAS_FRONTEND=true
    fi
    if echo "$CHANGED_FILES" | grep -qE "^(dang_articles/|dang_articles$)"; then
        HAS_ARTICLES=true
    fi

    if [ "$HAS_FRONTEND" = "true" ]; then
        warn "Detected frontend code changes, deploying frontend (blue/green)..."
        update_frontend
    elif [ "$HAS_ARTICLES" = "true" ]; then
        warn "Detected article changes only, updating articles..."
        update_articles "${diff_base}"
    else
        warn "Changes don't match articles or frontend patterns."
        warn "Use ./deploy.sh for full deployment, or specify manually:"
        warn "  ./hotfix.sh articles"
        warn "  ./hotfix.sh frontend"
        exit 1
    fi
}

# ============================================
# 主入口
# ============================================
preflight
ensure_submodules

case "${1:-auto}" in
    articles|article)
        update_articles
        ;;
    frontend|front)
        update_frontend
        ;;
    auto)
        auto_detect
        ;;
    *)
        echo "Usage: ./hotfix.sh [articles|frontend]"
        echo ""
        echo "  articles  - Update articles only (no downtime)"
        echo "  frontend  - Blue/green deploy frontend (no downtime)"
        echo "  (empty)   - Auto-detect from git changes"
        exit 1
        ;;
esac
