#!/usr/bin/env bash
#
# GitLab 備份腳本：一次產出「資料」+「設定金鑰」兩份，並清掉過期檔案。
#
#   ./backup.sh              一般備份
#   ./backup.sh --verify     備份後驗證 tar 完整性（較慢，建議每週跑一次）
#
# 排程範例（每天 03:00）：
#   0 3 * * * /home/shimai/workspace/docker-service/gitlab/backup.sh >> /var/log/gitlab-backup.log 2>&1
#
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a

BACKUP_DIR="${BACKUP_DIR:-./backups}"
CONFIG_DIR="$BACKUP_DIR/config"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-7}"
# 設了就把備份同步到異地；rsync 目標或 rclone remote 皆可
OFFSITE_RSYNC="${BACKUP_OFFSITE_RSYNC:-}"
OFFSITE_RCLONE="${BACKUP_OFFSITE_RCLONE:-}"

VERIFY=0
[ "${1:-}" = "--verify" ] && VERIFY=1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# 同一時間只允許一個備份在跑，避免 cron 疊加
exec 9>"${TMPDIR:-/tmp}/gitlab-backup.lock"
flock -n 9 || die "已有另一個備份程序在執行"

command -v docker >/dev/null || die "找不到 docker"
docker compose ps --status running --services 2>/dev/null | grep -qx gitlab \
  || die "gitlab 容器沒在跑，無法備份（請先 docker compose up -d）"

mkdir -p "$CONFIG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"

# --- 1. 資料：DB、repo、uploads、artifacts、LFS ---------------------------
# 產物會落在容器內的 /var/opt/gitlab/backups，也就是 host 的 ./backups
log "開始 gitlab-backup create ..."
docker compose exec -T gitlab gitlab-backup create CRON=1 \
  || die "gitlab-backup create 失敗"

# --- 2. 設定與金鑰：gitlab-backup 不含這些，缺了就解不開既有 token ---------
# 直接從容器內打包，省得處理 host 上 root 權限的檔案
CONFIG_TAR="$CONFIG_DIR/${TS}_gitlab-config.tar.gz"
log "打包 /etc/gitlab -> $CONFIG_TAR"
docker compose exec -T gitlab tar -czf - -C /etc/gitlab . > "$CONFIG_TAR.part" \
  || die "打包 /etc/gitlab 失敗"
mv "$CONFIG_TAR.part" "$CONFIG_TAR"
chmod 600 "$CONFIG_TAR"

# compose 設定與 .env 一起收進來，還原時才不用回想當初參數
ENV_TAR="$CONFIG_DIR/${TS}_compose.tar.gz"
tar -czf "$ENV_TAR" docker-compose.yml .env 2>/dev/null || true
chmod 600 "$ENV_TAR"

# --- 3. 驗證 -------------------------------------------------------------
if [ "$VERIFY" = 1 ]; then
  log "驗證 tar 完整性 ..."
  gzip -t "$CONFIG_TAR" || die "$CONFIG_TAR 損毀"
  LATEST_DATA="$(ls -t "$BACKUP_DIR"/*_gitlab_backup.tar 2>/dev/null | head -1 || true)"
  [ -n "$LATEST_DATA" ] && { tar -tf "$LATEST_DATA" >/dev/null || die "$LATEST_DATA 損毀"; }
  log "驗證通過"
fi

# --- 4. 清理過期備份 -----------------------------------------------------
log "清除 $KEEP_DAYS 天前的備份"
find "$BACKUP_DIR" -maxdepth 1 -name '*_gitlab_backup.tar' -mtime "+$KEEP_DAYS" -print -delete
find "$CONFIG_DIR" -maxdepth 1 -name '*.tar.gz' -mtime "+$KEEP_DAYS" -print -delete

# --- 5. 異地同步（選用）--------------------------------------------------
if [ -n "$OFFSITE_RSYNC" ]; then
  log "rsync -> $OFFSITE_RSYNC"
  rsync -a --delete-after "$BACKUP_DIR/" "$OFFSITE_RSYNC/" || log "WARN: rsync 失敗"
fi
if [ -n "$OFFSITE_RCLONE" ]; then
  log "rclone -> $OFFSITE_RCLONE"
  rclone sync "$BACKUP_DIR" "$OFFSITE_RCLONE" || log "WARN: rclone 失敗"
fi

log "完成。目前備份："
ls -lh "$BACKUP_DIR"/*_gitlab_backup.tar 2>/dev/null | tail -3 || true
ls -lh "$CONFIG_DIR"/*_gitlab-config.tar.gz 2>/dev/null | tail -3 || true
