# tmux-collie — 設計文件

> 狀態：草稿 v0.2（2026-10-24）｜取代 `docs/SCOPE.md` 的 phase 規劃
> 來源：本 repo 既有 P0/P1 實作 + 與 ChatGPT 討論的 `devflow` 設計（未讀過實際檔案）的整合

---

## 1. 定位

**一句話：** 在 tmux 裡管理「任務」——每個任務有自己的 worktree（可跨 repo）、自己的 tmux session、可替換的 agent，以及一份人與 agent 都讀得懂的任務合約；並讓你一眼看出哪個任務需要你。

**比喻：** 你是牧羊人（決策、驗收），collie 是牧羊犬（集合、看管、需要你時叫一聲）。

**對誰：** 不想離開 tmux / terminal，同時跑 3–5 個 agent、在多個 repo 之間切換的開發者。

**和相近工具的差別**

| | herdr | Orca | collie |
|---|---|---|---|
| 終端 | 自己就是 multiplexer（取代 tmux） | 桌面 GUI | 依附 tmux |
| 單位 | pane / agent | worktree | **task**（可含多個 repo 的 worktree） |
| 任務合約 | 無 | ? | `TASK.md`（目標、限制、驗收、下一步） |

---

## 2. 設計原則

1. **薄層，不重造輪子**：git / lazygit 管程式碼、tmux 管終端、agent 管對話。collie 只管「任務要什麼、在哪、誰在跑、下一步」。
2. **狀態優先「推導」而非「儲存」**：worktree 是否存在問 git，agent 是否活著問 tmux 和程序；只把推導不出來的東西（目標、優先級、人工狀態、歷史）存檔。推導不了 → 回報 `unknown`，不假裝。
3. **Task ≠ Agent Run**：agent 結束不代表任務完成；換 agent、重試都屬於同一個 task。
4. **非破壞性**：不改主 checkout、不自動 merge、不自動刪 branch、刪 worktree 前先檢查未 commit 與未合併的 commit。
5. **不碰使用者設定**：agent 的 hook 設定只印出片段（`collie doctor`），不改寫。
6. **零執行期依賴**：只需 bash 3.2、git、tmux、fzf；工作電腦和個人電腦行為一致。

### Non-goals
- 不是 agent，不呼叫 LLM API
- 不做 orchestration bus / 排程器 / 自動重啟 agent
- 不取代 lazygit 的 diff/commit，也不取代 sesh 這類 session manager
- 不處理跨 repo 的依賴同步（例如 subtree、版本號傳遞）——只保證相關 worktree 都在同一個 task 裡、路徑可查

---

## 3. 對 ChatGPT `devflow` 方案的取捨

| ChatGPT 建議 | 決定 | 理由 |
|---|---|---|
| Workspace / Repo / Task / Worktree / AgentRun / Event 六個實體 | **採用概念，精簡實作** | Task、AgentRun、Event 必要；Worktree 從 git 推導；Repo 用自動探索；Workspace 只是選用的 repo 組合捷徑 |
| Task 狀態與 Agent 狀態分兩條軸 | **採用** | 修正我先前把「agent 做完一輪」和「任務完成」都叫 `done` 的問題 |
| 9 種 task 狀態 | **精簡成 6 種** | `preparing / ready` 是暫態，`failed` 歸 `blocked`；狀態越少，越不會沒人維護 |
| `unknown` agent 狀態 | **採用** | 重開機、tmux 被關、程序消失時誠實回報 |
| Python + SQLite | **不採用，維持 bash + 檔案** | 見 §8 ADR-1 |
| worktree 集中放 `~/.local/share/devflow/worktrees/` | **不採用** | 你的 `.bare` 同層 worktree 習慣已經很好用，lazygit / nvim / 路徑記憶都依賴它；跨 repo 改用 task 資料夾 symlink 串起來 |
| 一個 task 一個 tmux session | **採用**（改掉 P1 的「一個 repo 一個 session」） | 切換任務 = 切 session，正中痛點 1 |
| `TASK.md` 合約 + 最終報告 | **採用** | 換 agent、隔天回來都靠它 |
| `recover` 指令 | **不另設指令** | `ls` 每次都重新推導狀態；`go` 發現 session 不見就重建 |
| 互動式啟動 agent，不做無人值守背景執行 | **採用** | 和我們原本「背景 = 沒切過去看的 tmux window」一致 |
| 建立失敗不留半成品、branch 已存在不覆蓋、刪除前確認 | **採用** | 列入每個 phase 的測試 |

---

## 4. 資料模型

```
Task 1 ── N Worktree   (每個 repo 一個；從 git 推導，task 檔只記 repo + branch)
Task 1 ── N AgentRun   (每次啟動一筆；runtime 狀態存在 tmux window option)
Task 1 ── N Event      (append-only log)
Repo                   (從設定的根目錄自動探索，不需手動註冊)
Workspace              (選用：具名的 repo 組合，只是建立 task 時的捷徑)
```

### 4.0 Task ID 與 branch

- **ID 一律用 slug**：`[a-z0-9-]`，最長 40 字元。工作上有 ticket 就放在 slug 開頭，例如 `dl-001-iceberg-rewrite`；個人專案就用 `deploy-v2` 這種描述。
- **branch 預設是 `<type>/<id>`**，`type` 預設為 `feat`，可以用 `-t fix` 等覆寫，符合你的 `<type>/<short-description>` 慣例。
- 也可以用 `-r repo:branch` 為個別 repo 指定 branch。

### 4.1 Task 狀態（人工為主）

| 狀態 | 意義 | 誰改 |
|---|---|---|
| `todo` | 已登記，還沒開始 | `collie new --todo` |
| `active` | 進行中 | `new` / `run` 自動 |
| `blocked` | 需要外部條件或人工決策 | 人工 |
| `review` | 等你檢查 | 人工或 agent 寫報告後 |
| `done` | 你確認符合驗收條件；worktree 已清掉，只留紀錄 | `collie done` |
| `archived` | 放棄的任務；worktree 已清掉，只留紀錄 | `collie archive` |

### 4.2 Agent Run 狀態（自動）

| 狀態 | 來源 |
|---|---|
| `working` | hook：使用者送出 prompt / agent 開始處理 |
| `waiting` | hook：agent 要求授權或提問 |
| `idle` | hook：agent 這一輪結束，等下一個指示（**不等於任務完成**） |
| `exited` | pane 裡的 agent 程序已不在 |
| `unknown` | tmux session 不見、或無法判斷 |

Dashboard 排序：`waiting` > `idle` > task `review` > task `blocked` > `working`（越需要你，越前面）。

### 4.3 檔案配置

```
~/.config/collie/config              # 可選；大部分設定走 tmux @collie-* option
~/.config/collie/workspaces          # 可選；一行一個：lakehouse: core jobs infra
~/.local/state/collie/tasks/<id>/    # 任務資料，worktree 刪掉後仍保留
  TASK.md        # 合約 + frontmatter（狀態、優先級、下一步）
  repos.tsv      # 機器用：name<TAB>git common dir<TAB>branch<TAB>worktree path
  NOTES.md       # 人和 agent 的進度筆記（park 用）
  REPORT.md      # agent 結束時寫的報告
  events.log     # append-only：ts<TAB>event<TAB>k=v ...
  repos/<repo> -> 實際 worktree 路徑（symlink）

<repo-root>/<slug>/                  # worktree：維持 .bare 同層 / <repo>.worktrees/
  .collie -> ~/.local/state/collie/tasks/<id>   # 讓 agent 在 cwd 就讀得到任務檔
```

- `.collie` 寫進 repo 的 `$GIT_COMMON_DIR/info/exclude`，不碰你的全域 gitignore，也不會被 commit。
- tmux session 透過環境變數 `COLLIE_TASK` 和 `COLLIE_TASK_DIR` 讓 hook 和 agent 知道自己屬於哪個 task。

### 4.4 `TASK.md` 格式

```markdown
---
id: deploy-v2
title: A 新版號帶到 B deploy
status: active
priority: P1
next: 確認 B 的 deploy script 讀版號的位置
created: 2026-10-24
---
## Objective
## Context
## Constraints
- 不修改主 checkout；不 merge；不刪 branch
## Acceptance Criteria
## Verify
<驗證指令>
```

frontmatter 只用扁平的 `key: value`，bash/awk 就能解析。repo 清單不放在 frontmatter，而是存在 `repos.tsv`：人改 TASK.md，程式讀 repos.tsv，兩邊不會互相弄壞。

**輕量 task：** 只有 frontmatter 是必要的，body 的各個段落都可以留空。`collie new` 預設**不開編輯器**，只寫入 `title`（沒給就用 id）；要寫完整合約時加 `--edit`。agent 啟動時如果發現 Objective 是空的，就先向你確認目標。

---

## 5. 指令介面

### 日常

| 指令 | 用途 |
|---|---|
| `collie new <id> [-r repo[:branch]]... [-w workspace] [-t type] [--title ..] [--from ref] [--todo] [--edit]` | 建 task、worktree、session；沒給 `-r` / `-w` 就用目前所在的 repo |
| `collie add [<id>] -r repo[:branch]` | 任務進行到一半才發現要動另一個 repo 時，把它加進既有的 task |
| `collie ls` | 所有活躍 task：id、優先級、task 狀態、agent 狀態、repo、下一步 |
| `collie go [<id>]` | 切到 task session（沒給就開 fzf）；session 不見就重建；在 tmux 外則印出路徑 |
| `collie run [<id>] [--agent X]` | 在 task session 開新 window 啟動 agent，記錄一筆 run |
| `collie set [<id>] status=review next="..."` | 改 task 狀態或下一步（agent 也可以呼叫） |
| `collie review [<id>]` | 各 repo 的 diff stat + REPORT.md；按鍵開 lazygit |
| `collie done [<id>]` | 驗收，並在檢查通過後直接 archive（小修改一個指令收尾） |
| `collie archive [<id>]` | 不經驗收直接收掉（放棄的任務）；同樣有安全檢查 |
| `collie gc` | 列出 branch 已合併的 task，用 fzf 多選後 archive |

### 管理

| 指令 | 用途 |
|---|---|
| `collie state <working\|waiting\|idle>` | agent hook 呼叫的端點 |
| `collie show <id>` | 單一 task 的完整資訊 + 最近事件 |
| `collie doctor` | 依賴檢查、已安裝 agent、hook 設定片段、task / git / tmux 對帳 |
| `collie repos` | 列出探索到的 repo |
| `collie workspaces` | 列出 workspace 和各自包含的 repo |

`<id>` 省略時，從目前的 tmux session 或 `$COLLIE_TASK` 推得。

### tmux 快捷鍵（`@collie-key` 可覆寫；預設避開常見綁定）

只占用**一個** prefix 鍵：`prefix h`（**h**erd），打開 `display-menu` 選單，選單上會列出每個字母對應的動作，不用背：

```
prefix h →  ┌ collie ──────────────┐
            │ h  dashboard         │   ← prefix h h：最常用的再按一次 h
            │ g  lazygit           │
            │ n  notes / next      │
            │ r  run agent         │
            │ v  review            │
            │ s  set status        │
            │ d  done              │
            └──────────────────────┘
```

另外建議在 Alacritty 加一個直達 dashboard 的鍵（例如 `Cmd+J`），這屬於 dotfiles 的設定。

（已對照你目前的 tmux 綁定：`h` 是空的；`a`、`C`、`T` 已被占用。）

---

## 6. Agent adapter

每個 agent 一個 `agents/<name>.sh`，實作四個函式：

```bash
agent_detect          # command -v，判斷是否安裝
agent_launch_cmd      # 產生在 worktree 裡啟動的指令（含讀取 .collie/TASK.md 的提示）
agent_extra_dirs      # 跨 repo 時授權其他 worktree 的方式（claude: --add-dir）
agent_hook_snippet    # 給 doctor 印出的 hook 設定
```

| Agent | 狀態來源 | 確認程度 |
|---|---|---|
| claude | hooks：`UserPromptSubmit` → working、`Notification` → waiting、`Stop` → idle | 確定 |
| omp | 參考 Orca 的做法 | 待 P4 研究 |
| codex | `notify`（turn 結束 → idle）+ silence 偵測 | 未驗證 |
| gemini | 可能有 hooks | 未驗證 |
| generic | tmux `monitor-silence` + 程序結束偵測 | 一定可用，但粗略 |

`exited` / `unknown` 不靠 hook，由 `ls` 推導：檢查 window 是否存在，以及 pane 的前景程序是否還是 agent（`#{pane_current_command}`）。

---

## 7. Phases

每個 phase 都能獨立使用；每個驗收項目都要有自動測試，除非標明「手動」。

### P0 — Foundation ✅（已完成，在 `feat/plugin-skeleton`）
- tpm 進入點、PATH 注入、bats + 獨立 tmux server 測試框架、shellcheck、CI 設定
- **保留不動**

### P1 — Task model ✅（已實作，尚未 commit；26 個測試通過）
**目標：** task 成為核心單位，支援單 repo 和跨 repo。
- repo 探索（`@collie-repo-roots`，例如 `~/Repos/*/*`），支援 bare 和一般 clone
- `new / add / ls / show / go / done / archive`；`-w workspace`、`-t type`、slug 驗證
- task 資料夾、`TASK.md` 模板（輕量為預設）與 frontmatter 解析、`events.log`
- 一個 task 一個 session；每個 repo 一個 window；`.collie` symlink + `info/exclude`
- 沿用現有 `load_repo`、worktree 建立邏輯和測試
- **驗收：**
  - 建一個單 repo task 和一個跨 2 個 repo 的 task，branch、檔案、session 互不干擾
  - `tmux kill-server` 之後，`ls` 仍列出 task，`go` 能重建 session
  - 建立到一半失敗（例如第 2 個 repo 的 branch 已被別的 worktree 使用）→ 已建的 worktree 回滾，不留半成品
  - `archive` 遇到未 commit 或未合併到 base 的 commit → 拒絕並列出
  - `new -w lakehouse` 一次開齊 workspace 裡的 repo；`add` 能把新 repo 加進既有的 task
  - 小修改流程只需兩個指令：`collie new fix-typo` → 修改、commit、merge → `collie done`

### P2 — Agent runtime
**目標：** 知道每個 agent 在幹嘛。
- `run`、`state`；claude adapter + generic adapter
- `exited / unknown` 推導；每次 run 寫入 events
- status bar 圖示；`waiting / idle` 時發通知（macOS / Linux，可關掉）
- **驗收：**
  - 3 個 task 同時跑，狀態切換正確（用假的 agent 腳本模擬 hook 測試）
  - 砍掉 agent 程序 → `exited`；`kill-server` → `unknown`
  - 手動：用真的 Claude Code 走一輪 working → idle

### P3 — Dashboard 與操作
**目標：** 任何 pane 按兩個鍵內就能到需要你的那個 agent。
- fzf dashboard（依 §4.2 排序；preview 顯示 next、diff stat、NOTES 最後幾行）
- lazygit / NOTES popup；`set`；zsh 補全
- 文件：Alacritty 鍵位對應範例
- **驗收：** dashboard 排序測試；手動確認在實際環境中好用

### P4 — 更多 agent 與 doctor
- 研究 Orca 怎麼接 omp → omp adapter；codex、gemini adapter
- `doctor`：依賴版本、hook 設定片段、task / git / tmux 對帳
- **驗收：** 每個 adapter 用假 agent 測 working → idle；手動測 omp

### P5 — Review 與生命週期
- `review`（多 repo diff + REPORT）、`done`
- `spike`：帶著未 commit 的修改開 `exp/*`，不動原 worktree
- `park`：寫下一步到 NOTES 和 frontmatter
- `exp/*` 防 push（可選的 pre-push hook 片段）
- **驗收：** spike 後原 worktree 的 `git status` 不變；review 能顯示 2 個 repo 的 diff

### P6 — 多 agent 協作（等前面每天都在用再做）
- 同一個 task 跑第二個 run（例如 claude 規劃、omp 實作）
- `review --agent X`：非互動審查，寫入 REVIEW.md
- `race`：同一份 TASK 給 N 個 agent，各自一個 worktree

### 另外：dotfiles 整合（在 dotfiles repo 做，P2 之後）
- `tmux.conf` 加 `@plugin` 和 `@collie-*` 設定；`tmux.conf.local` 放工作電腦的覆寫
- `.claude/settings.json` hooks；Alacritty 鍵位（例如 `Cmd+J` → dashboard）；zsh 補全
- 工作電腦 bootstrap：`./install` 加 `prefix I`

---

## 8. 決策紀錄（ADR）

### ADR-1：bash + 檔案，不用 Python + SQLite
- **背景：** ChatGPT 建議 Python + SQLite，理由是多個 agent 同時寫入狀態。
- **決定：** 維持 bash 3.2 + 純檔案。
- **理由：**
  - 寫入量很小：agent 狀態寫在 tmux option（tmux server 本身就會序列化處理）；events 是單行 append（一行小於 PIPE_BUF 時，`>>` 寫入是原子的）。沒有需要交易的情境。
  - 依照原則 2，大部分狀態都是推導出來的，資料庫反而會變成第二個需要對帳的真相來源。
  - 這個工具 90% 是在呼叫 git 和 tmux，bash 最直接；也不需要額外的執行環境。
  - P0/P1 已經用 bash 寫好，測試框架也在。
- **重新評估條件：** 核心超過約 1500 行、需要跨 task 的複雜查詢、或 frontmatter 解析開始容易出錯 → 把核心改寫成 Python（只用標準函式庫），CLI 介面維持不變。

### ADR-2：worktree 維持放在 repo 旁邊
- 你的 `.bare` 同層 worktree 習慣，以及既有工具的路徑都依賴它；跨 repo 的需求用 task 資料夾 symlink 解決。

### ADR-3：一個 task 一個 session
- 取代 P1 的一個 repo 一個 session。代價是 session 數量變多，靠 dashboard 和 fzf 處理。

---

## 9. 風險與防護（每項都對應到測試）

| 風險 | 防護 |
|---|---|
| 建立到一半失敗 | 逐步記錄已建立的 worktree，失敗時反向回滾 |
| branch 已被其他 worktree 使用 | 先檢查；拒絕，並告訴你是哪個 task 在用 |
| 刪掉有價值的工作 | `archive` 檢查 dirty 和未合併的 commit；不用 `--force` 就拒絕 |
| 改到主 checkout | 永遠只用 `worktree add`；不在既有 worktree 裡 checkout |
| 狀態和現實不一致 | 每次 `ls` 都推導；推導不了就顯示 `unknown` |
| agent sandbox 擋 symlink | 預設在主 repo 啟動 + adapter 的 `extra_dirs`；symlink 只當備援 |

---

## 10. 已決定事項

| # | 問題 | 決定 |
|---|---|---|
| 1 | Task ID 格式 | 一律用 slug；有 ticket 就放在開頭（`dl-001-...`） |
| 2 | Workspace | 選用的具名 repo 組合（`-w`），提前到 P1；`-r` 仍可單獨使用；另有 `add` 讓 task 中途加 repo |
| 3 | 小修改也建 task | 是。規則：**會產生 branch 的工作就是 task**；只讀、探索不需要。task 預設輕量（不開編輯器），用 `done` 一個指令收尾，`gc` 批次清理 |
| 4 | 快捷鍵 | `prefix h`（herd）開選單，`prefix h h` 直達 dashboard；Alacritty 另設直達鍵 |
