# GitLab 備份決策紀錄

2026-08-14

操作說明看 [README](README.md#備份與還原)。這份只記「為什麼這樣選」跟「還沒決定的事」。

## 起點：怕誤刪 volumes

先釐清一件事——**這份設定不會被誤刪 volume 害到**。用的是 bind mount
（`./data/config`、`./data/data`），不是 Docker named volume，所以
`docker compose down -v` 和 `docker volume prune` 對資料完全無效。

真正的風險是別的：

- `rm -rf` 到專案目錄（而 `./backups` 預設就在同一層，會一起沒）
- 磁碟 / 檔案系統損毀
- WSL2 被 `wsl --unregister`，或 Docker Desktop 按到 *Reset to factory defaults*
- 整台機器不見（火災、失竊、勒索軟體）

所以防護重點放在「備份要離開這個目錄、這顆碟、這台機器」，而不是去管 volume 指令。

## 已做（commit 35be6bc）

`backup.sh` 一次備三樣，缺一還原就會出事：

1. `gitlab-backup create` — DB、repo、uploads、artifacts、LFS
2. 容器內打包 `/etc/gitlab` — **含 `gitlab-secrets.json`**
3. `docker-compose.yml` + `.env`

第 2 點是最容易漏的：`gitlab-backup` 的 tar **不含** `gitlab-secrets.json`。
少了它，CI/CD 變數、PAT、2FA 種子、整合設定全部解不開，還原後會得到一個
「資料在、但每個 token 都是廢的」GitLab。

另外把備份輸出改成 `GITLAB_BACKUP_PATH` 可設定（預設 `./backups`，正式環境指到
專案目錄外的另一顆碟），並加上 `backup_keep_time` 輪替與
`backup_archive_permissions = 0600`（備份 tar 裡是全部 repo，別讓同機其他帳號讀）。

## 評估過但排除：熱複製整包目錄

不停機直接 `tar` / `rsync` 整個 `./data`——**不要做**。

底下有活著的 PostgreSQL 和正在寫 packfile 的 Gitaly。rsync 跑五分鐘，就是在五分鐘的
時間跨度裡拼一份快照，A 檔案是 03:00 的狀態、B 檔案是 03:04 的，中間 checkpoint 和
WAL 都動過。不是原子的。

最麻煩的是**它通常不會當場報錯**：還原回去 Postgres 跑完 crash recovery 就起來了，
網頁也打得開，直到某天 clone 某個 repo 才發現 packfile 是斷的。備份監控全綠燈，
資料靜靜地壞著。

> 若有 LVM / ZFS / btrfs，快照是原子的，沒有這個問題，反而是最優解。
> 但本機是 WSL2 上的 ext4（`/dev/sdd` 單一裝置），無 lvm/zfs/btrfs，這條路走不通。

## 待決定：冷複製整包目錄（每週一次）

先 `docker compose down` 再整包複製。官方認可，一致性沒問題。

| | `gitlab-backup create` | 冷複製整包 |
| --- | --- | --- |
| 停機 | 不用 | 要（數分鐘） |
| 含 secrets | 要另外處理 | 自動含 |
| 還原速度 | 慢（import DB + 解壓 repo） | 快（複製回去即可） |
| **跨版本還原** | 支援 | 必須完全同版本 |
| **單一 project 還原** | 可以 | 只能整包 |
| 體積 | 小 | 大（含 log、cache、redis） |

下面兩列是冷複製的真正代價。實際要動用備份的場合，很多時候是「搬新機器順便升版」，
那時 `gitlab-backup` 的跨版本還原路徑是唯一出路；而「某個 project 被誤刪想救回來」
這種最常見的小災難，冷複製要嘛全還原、要嘛另開臨時機器撈。

**傾向：兩個都要，分工不同。** `gitlab-backup` 每天跑（日常、小災難、搬遷升版），
冷複製每週一次（災難還原，換取整機炸掉能在十分鐘內原樣復活）。單機自架、
半夜停機三分鐘沒成本，所以划算。

若要做，用 pre-sync 把停機壓到幾十秒：
熱 rsync 一次（不求一致，先搬走 99%）→ `down` → rsync delta（很快）→ `up -d`。
最終那份在停機狀態下對齊，一致性有保證。

**狀態：使用者評估中，尚未實作。** 要做的話是加 `./backup.sh --cold`，
含 pre-sync、停機 delta、排除 `logs/` `tmp/` cache。

## 不管選哪個都要做的

- `.env` 設 `GITLAB_BACKUP_PATH` 到專案外的另一顆碟
- 異地一份（`BACKUP_OFFSITE_RSYNC` / `BACKUP_OFFSITE_RCLONE`），
  雲端開 object lock / 版本保留——勒索軟體會連掛載的網路磁碟一起加密，
  擋得住的只有對方刪不掉的不可變儲存
- 備份目錄 `chown root:root` + `chmod 700`
- **每季演練一次完整還原**，確認登得進去、clone 得下來、CI 變數還在。
  沒演練過的備份等於沒有備份
