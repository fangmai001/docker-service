# docker-service

自架服務的 Docker Compose 設定集。每個服務一個資料夾，各自獨立，
可以只挑需要的那個來用。

## 服務清單

| 服務 | 說明 | 狀態 |
| --- | --- | --- |
| [gitlab](./gitlab) | GitLab EE 19.2.2（Free 版功能）+ 選用的 GitLab Runner | 已實測可用 |

## 使用方式

每個資料夾的用法都一樣：

```bash
cd <服務名稱>
cp .env.example .env    # 依註解修改設定，密碼類欄位務必改掉
docker compose up -d
```

詳細設定、port、備份還原方式請看各服務資料夾裡的 `README.md`。

## 慣例

- 所有可調整的參數都放在 `.env`，compose 檔本身不寫死主機名稱、port 或密碼。
- `.env` 不進版控，只提交 `.env.example` 範本。
- 執行期資料掛載在各服務資料夾的 `data/` 底下，備份放 `backups/`，兩者都已排除在版控之外。

## 環境

開發與測試環境為 WSL2（Ubuntu）+ Docker Compose v5。
其他 Linux 發行版應該可以直接使用；macOS 需注意 bind mount 的效能與權限差異。

## License

[MIT](./LICENSE)
