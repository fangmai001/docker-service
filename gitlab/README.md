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

```bash
# 備份（產出在 ./backups）
docker compose exec gitlab gitlab-backup create

# 還原（BACKUP 換成檔名中 _gitlab_backup.tar 前面那段）
docker compose exec gitlab gitlab-ctl stop puma
docker compose exec gitlab gitlab-ctl stop sidekiq
docker compose exec gitlab gitlab-backup restore BACKUP=<timestamp>
docker compose restart gitlab
```

`gitlab-backup` **不含** `/etc/gitlab` 底下的設定與金鑰（`gitlab-secrets.json`），
那部分已掛在 `./data/config`，請一併備份，否則還原後無法解密既有的 CI 變數與 token。

## GitLab Runner（選用）

```bash
docker compose --profile runner up -d
docker compose exec gitlab-runner gitlab-runner register
```

註冊時 URL 填 `http://<你的主機IP>:8929`（不要用 `localhost`，
runner 在另一個容器裡，localhost 指向它自己）。

## LDAP（選用）

要接公司內網既有的 AD，打開 `docker-compose.yml` 裡
`GITLAB_OMNIBUS_CONFIG` 中被註解掉的 LDAP 區塊，填好這幾個欄位：

| 欄位 | 說明 |
| --- | --- |
| `host` | 內網 AD 主機名稱或 IP |
| `bind_dn` | 用來查詢目錄的服務帳號（DN 全名） |
| `password` | 該服務帳號的密碼 |
| `base` | 搜尋使用者的 base DN |

- 內網走明碼 389 用 `encryption = 'plain'`；若 AD 有開 LDAPS，改成
  `'simple_tls'` 並將 `port` 改成 `636`。
- 改完存檔後 `docker compose up -d` 觸發 reconfigure（約 1–2 分鐘）。
- 驗證：`docker compose logs -f gitlab` 確認沒有 `FATAL`；登入頁
  （http://localhost:8929/users/sign_in）應該會出現 LDAP 登入選項；
  用一組內網帳密實際登入測試。

`bind_dn`/`password` 是明碼寫在 `docker-compose.yml`，且會落到容器內
`/etc/gitlab/gitlab.rb`（即 `./data/config`）。填入真實密碼後注意別把
`docker-compose.yml` 的敏感值 commit 上去。

## 目錄

```
data/config   → /etc/gitlab       設定與金鑰
data/logs     → /var/log/gitlab   日誌
data/data     → /var/opt/gitlab   資料庫、repo、上傳檔
backups/      → 備份輸出
```

`.env`、`data/`、`backups/`、`runner/` 已列入 `.gitignore`。
