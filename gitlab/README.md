# GitLab (Docker Compose)

自架 GitLab CE/EE 單機測試環境。使用本機已有的 image `gitlab/gitlab-ee:19.2.2-ee.0`
（EE image 不上傳 license 就是 Free 版功能，與 CE 相同）。

## 快速開始

```bash
cp .env.example .env      # 首次使用，並修改 GITLAB_ROOT_PASSWORD
docker compose up -d
docker compose logs -f gitlab
```

首次啟動要跑 DB migration 與 reconfigure，約 5–10 分鐘。

注意 healthcheck 變 `healthy` 時 Rails 通常還在開機，這時開網頁會看到 502
「Waiting for GitLab to boot」。以實際 HTTP 回應為準：

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8929/users/sign_in
# 回 200 才是真的可以用了
```

- Web： http://localhost:8929
- 帳號： `root`
- 密碼： `.env` 裡的 `GITLAB_ROOT_PASSWORD`
- SSH clone： `ssh://git@localhost:2224/<group>/<project>.git`

## 設定說明

所有可調參數都在 `.env`：

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `GITLAB_VERSION` | `19.2.2-ee.0` | image tag |
| `GITLAB_HOST` | `localhost` | 對外主機名稱；要給區網其他機器連就改成本機 IP |
| `GITLAB_HTTP_PORT` | `8929` | Web port |
| `GITLAB_SSH_PORT` | `2224` | git over SSH 的 port（避開 host 的 22） |
| `GITLAB_ROOT_PASSWORD` | — | 初始 root 密碼，**必填**，至少 8 碼 |

### 為什麼 port 是 `8929:8929` 而不是 `8929:80`

`external_url` 一旦帶上 port，容器內的 nginx 就會直接聽那個 port，
所以 host 與 container 的 port 必須一致，否則會連不上或被導向錯的網址。

改 `GITLAB_HOST` / `GITLAB_HTTP_PORT` 後要重跑 `docker compose up -d`，
GitLab 會重新 reconfigure（約 1–2 分鐘）。

### 資源

這份設定針對小記憶體機器做了精簡：關掉 Prometheus / Grafana / KAS / Registry /
gitlab-exporter，`puma['worker_processes'] = 0`（單進程模式）。
正式使用建議記憶體 8GB 以上，並把 `puma['worker_processes']` 調回 `2`。

WSL2 上若記憶體不足，可在 Windows 的 `%USERPROFILE%\.wslconfig` 加上：

```ini
[wsl2]
memory=8GB
```

改完執行 `wsl --shutdown` 再重開。

## 常用指令

```bash
docker compose logs -f gitlab                  # 看啟動進度
docker compose exec gitlab gitlab-ctl status   # 各元件狀態
docker compose exec gitlab gitlab-ctl reconfigure
docker compose exec gitlab gitlab-rails console -e production

docker compose restart gitlab
docker compose down                            # 停止（資料保留在 ./data）
```

## 疑難排解

**容器不斷重啟、log 出現 `Reading unsupported config value xxx`**

`GITLAB_OMNIBUS_CONFIG` 裡有這個版本已經移除的設定，reconfigure 會直接 FATAL。
把該行刪掉再 `docker compose up -d --force-recreate` 即可。
例如 `grafana['enable']` 在 19 版已不存在（omnibus 從 16.3 起移除 Grafana）。

```bash
docker logs gitlab 2>&1 | grep -iE 'FATAL|unsupported'
```

## 備份與還原

### 先搞清楚風險在哪

這份設定用的是 **bind mount**（`./data/...`）而不是 Docker named volume，所以：

- `docker compose down -v` **不會**刪掉你的資料，`docker volume prune` 也不會。
- 真正會讓資料消失的是：`rm -rf` 到專案目錄、磁碟或檔案系統壞掉、
  WSL2 被 `wsl --unregister` 或 Docker Desktop 按下 *Reset to factory defaults*、
  以及整台機器不見（火災、失竊、被加密勒索）。

換句話說，防的不是 volume 指令，是**人手滑和機器掛掉**。所以備份的第一原則是
**備份不能跟資料放在同一個目錄、同一顆碟、同一台機器**。

### 三樣東西都要備，缺一還原就會卡住

| 內容 | 來源 | 由誰處理 |
| --- | --- | --- |
| DB、repo、uploads、artifacts、LFS | `gitlab-backup create` | `backup.sh` 第 1 步 |
| `/etc/gitlab`（`gitlab-secrets.json`、`gitlab.rb`） | 容器內打包 | `backup.sh` 第 2 步 |
| `docker-compose.yml`、`.env` | 專案目錄 | `backup.sh` 第 2 步 |

最常見的災難是只留了 `gitlab-backup` 的 tar：那包**不含** `gitlab-secrets.json`，
少了它，所有 CI/CD 變數、Personal Access Token、2FA 種子、整合設定都解不開，
還原完會得到一個「資料在、但每個 token 都失效」的 GitLab。

### 用 backup.sh

```bash
./backup.sh              # 一般備份
./backup.sh --verify     # 額外驗證 tar 完整性，建議每週一次
```

腳本會依序做：`gitlab-backup create` → 打包 `/etc/gitlab` 與 compose 設定 →
（`--verify`）驗證 → 刪除 `BACKUP_KEEP_DAYS` 天前的舊檔 → 異地同步（若有設定）。
用 `flock` 上鎖，cron 疊到也不會兩個同時跑。

排程（crontab -e）：

```cron
0 3 * * 1-6  /home/shimai/workspace/docker-service/gitlab/backup.sh          >> /var/log/gitlab-backup.log 2>&1
0 3 * * 0    /home/shimai/workspace/docker-service/gitlab/backup.sh --verify >> /var/log/gitlab-backup.log 2>&1
```

### 3-2-1：至少要做到「另一顆碟 + 另一個地方」

在 `.env` 設定：

```bash
# 1. 備份寫到專案目錄外、不同實體碟
GITLAB_BACKUP_PATH=/mnt/backup/gitlab

# 2. 再同步一份到別台機器 / 雲端（二選一）
BACKUP_OFFSITE_RSYNC=user@nas:/volume1/backup/gitlab
BACKUP_OFFSITE_RCLONE=b2:my-bucket/gitlab
```

`GITLAB_BACKUP_PATH` 改完要 `docker compose up -d` 讓 mount 生效。

雲端那份建議開 **object lock / 版本保留**（B2、S3、Wasabi 都有）。
勒索軟體會連著網路磁碟一起加密，唯一擋得住的是對方刪不掉的不可變儲存。

### 防手滑的幾個小動作

```bash
# 備份目錄設成 root-only，一般帳號的 rm 直接失敗
sudo chown root:root /mnt/backup/gitlab && sudo chmod 700 /mnt/backup/gitlab

# 更狠一點：讓最近一份備份連 root 都刪不掉（要刪先 chattr -i）
sudo chattr +i /mnt/backup/gitlab/最新那份_gitlab_backup.tar
```

另外，把 `docker compose down -v` 從肌肉記憶裡拿掉、資料目錄不要跟其他專案混在
同一層，這兩件事的效果比任何腳本都好。

### 還原

**版本必須一致。** 用哪個 tag 備的，就要用同一個 tag 還原，`.env` 的
`GITLAB_VERSION` 不要動。順序是「先設定、後資料」：

```bash
# 1. 先把設定與金鑰放回去（含 gitlab-secrets.json）
docker compose up -d
docker compose exec -T gitlab tar -xzf - -C /etc/gitlab < backups/config/<TS>_gitlab-config.tar.gz
docker compose exec gitlab gitlab-ctl reconfigure
docker compose exec gitlab gitlab-ctl restart

# 2. 把備份 tar 放進 GITLAB_BACKUP_PATH，確認容器內看得到
docker compose exec gitlab ls -l /var/opt/gitlab/backups

# 3. 停掉會寫入的服務再還原（BACKUP 填檔名中 _gitlab_backup.tar 前面那段）
docker compose exec gitlab gitlab-ctl stop puma
docker compose exec gitlab gitlab-ctl stop sidekiq
docker compose exec gitlab gitlab-backup restore BACKUP=<timestamp> force=yes

# 4. 起回來並檢查
docker compose restart gitlab
docker compose exec gitlab gitlab-ctl reconfigure
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
docker compose exec gitlab gitlab-rake gitlab:doctor:secrets   # 金鑰對不對，這步最關鍵
```

`gitlab:doctor:secrets` 若報一堆解密失敗，代表 `gitlab-secrets.json` 不是同一份，
回去確認第 1 步的 config tar 有沒有蓋對。

### 為什麼是這套機制

選型過程、排除掉的做法（熱複製整包目錄）、以及還在評估的冷複製，
記在 [BACKUP-NOTES.md](BACKUP-NOTES.md)。

### 沒演練過的備份等於沒有備份

至少每季一次，在另一台機器（或另開一份 compose、換 port）拿最新的備份完整還原一次，
確認能登入、repo clone 得下來、CI 變數還在。這件事沒做，前面所有設定都只是心安。

## GitLab Runner（選用）

```bash
docker compose --profile runner up -d
docker compose exec gitlab-runner gitlab-runner register
```

註冊時 URL 填 `http://<你的主機IP>:8929`（不要用 `localhost`，
runner 在另一個容器裡，localhost 指向它自己）。

## 目錄

```
backup.sh     備份腳本（資料 + 金鑰 + compose 設定）
data/config   → /etc/gitlab       設定與金鑰
data/logs     → /var/log/gitlab   日誌
data/data     → /var/opt/gitlab   資料庫、repo、上傳檔
backups/      → 備份輸出（可用 GITLAB_BACKUP_PATH 移到專案外）
  config/       /etc/gitlab 與 compose 設定的打包
```

`.env`、`data/`、`backups/`、`runner/` 已列入 `.gitignore`。
