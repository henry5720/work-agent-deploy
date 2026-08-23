# 分離 backlog agent 與 execution agent，按 thread 隔離 workspace

## Status

Superseded by [0006](0006-readonly-product-context-handoff-bot.md)。

## Background

現有 backlog agent 的定位是共享、低權限地整理 Slack 待辦，這個邊界不應因為需要執行已核准
工作而擴張。另一方面，PDF、Office、audio、video 與需要較長處理鏈的工作，需要一個能在
thread 脈絡中持續處理的 execution agent。OpenAB 的 session routing 只負責把互動送到正確
session，不等於 filesystem isolation；若沒有 thread workspace，artifact 與 session 內容會
互相污染，也無法可靠清理。

## Decision

- 保留現有低權限 backlog agent，新增 OpenCode + oh-my-opencode-slim execution agent；兩者
  的職責與權限分離。
- execution agent 使用原生 `opencode acp`，並透過公司的 OpenAI-compatible gateway 工作。
- 圖片生成與編輯一律使用公司 gateway 的 Responses API `image_generation` tool；編輯用的 input
  image 以 JSON input 傳入。不得使用與 gateway 不相容的 multipart `/images/edits`。
- Codex CLI 不是固定的中間層。Claude 只有在使用者明確同意，且本機處理已被具體 blocker
  阻塞時才可使用。
- 每個 Slack thread 建立自己的 thread workspace，key 由 Slack workspace、user、channel
  與 thread 組成；workspace 從指定的 shared repo snapshot 建立可寫副本。execution agent
  只能修改這份副本，不得修改 shared snapshot，也不得執行 Git push。
- code task 的第一個指令必須明確選擇 `config/repos.conf` allowlist 中的 repo slug。未選定
  repo 前，只可處理通用檔案或問答，不得進入任何 repo 的 code task。
- execution agent v1 接受 image、text、audio、PDF、DOCX、PPTX、XLSX、CSV；拒絕 ZIP 與 video，
  並向使用者說明原因。
- 附件單檔上限 20MB，每個 thread 最多 5 檔，解壓後內容上限 100MB；超過上限即拒絕並說明
  原因。
- OpenAB native inbound 只涵蓋 image、audio、text；其餘接受的格式由受限制的自訂下載與檢查
  流程處理。
- code task 預設交付 patch/diff 與測試摘要；只有使用者明確要求時才製作完整 ZIP。結果經受限的
  local upload helper 回到原 Slack thread；Slack token 不暴露給 agent。
- execution agent 的網路 egress 僅允許公司 gateway；任意網際網路、Git remote、package registry
  與內網連線一律拒絕。Slack upload 由受限的 local upload helper 處理。
- 每個 Slack thread 使用一個暫時的 OpenCode + OMO（oh-my-opencode-slim）container；全域
  execution concurrency 固定為 1。container 在工作完成或 session 閒置 4 小時後銷毀。
- 原始與衍生 artifacts 的 outer TTL 維持最長 24 小時，成功上傳後儘早刪除。
- rollout 初始 resource cap 為 2 CPU、2GiB memory、256 PIDs、512MiB tmpfs。這些是依已量測
  的 deployment host 容量選定的第一版 cap，需監控後才能調高。
- 從 shared snapshot 建立的可寫副本依實際內容大小估算，並受 quota 限制。
- outbound consent 採每 thread 首次確認，不跨 thread 沿用。
- 模型使用者選擇暫與本機共用既有公司 gateway key。該 key 僅作部署 secret，不得進入 Git、
  設定檔、skill 或 artifact。
- 由 `work-helper` 作遠端 skills 的正本，採三支 remote-specific skills：
  `local-artifact-intake`、`slack-artifacts`、`company-imagegen`，同時同步現有 `work-helper`
  skills。skills 不帶密鑰；同步只提供行為能力，不構成授權。行為權限由 runtime gates（agent
  role、filesystem gate 與 egress gate）決定。

## Consequences

- backlog agent 可以維持共享低權限的待辦整理邊界，不必取得 execution agent 的處理能力。
- execution agent 可以在同一個 GPT agent 內處理 thread 的工作脈絡與最小 artifacts，不必把
  Codex CLI 當成固定轉接層。
- execution agent v1 的輸入邊界可預期；ZIP 與 video 不進入處理範圍，使用者會收到拒絕原因。
- OpenAB native inbound 的涵蓋範圍有限，其他支援格式需要額外維持受限制的下載與檢查邊界。
- 產物回傳不需要把 Slack token 交給 agent，但會增加 local upload helper 的可靠性與清理責任。
- code task 預設只需傳回 patch/diff 與測試摘要，可減少不必要的完整副本傳送；完整 ZIP 只有使用者
  明確要求時才產生，因此該要求會增加 artifact 大小、清理與上傳負擔。
- 已驗證 Responses API 的 edit 路徑是 implementation constraint：圖片編輯 client、skill 與
  runtime 必須使用 `image_generation` tool 的 JSON input image；與 gateway 不相容的 multipart
  `/images/edits` 不是可用的 fallback，誤用會造成介面相容性失敗。
- gateway-only egress 可阻止 execution agent 連到任意網際網路、Git remote、package registry 與
  內網，但也代表需要套件或遠端資料的工作必須改由受控流程提供輸入，否則會被拒絕。
- thread workspace 提供 session 之間的內容邊界，但會增加 workspace 建立、生命週期與清理
  失敗的管理責任；每 thread 一個暫時 container 與全域 concurrency=1 會限制同時處理量。
- 從指定 snapshot 建立可寫副本可讓 execution agent 產生可審查的 patch、diff 或 ZIP，且不會
  直接改動 shared snapshot 或推送 Git；代價是後續套用結果仍需由受控流程處理。
- 完成或閒置 4 小時即銷毀 container，且 artifact outer TTL 為 24 小時，可限制殘留資料；
  這也要求清理失敗可被發現與處理，成功上傳後應儘早刪除。
- 初始 resource cap 可把 rollout 的資源使用限制在已量測容量可承受的第一版範圍；調高 cap
  前必須先依監控結果確認。可寫副本的 quota 則避免依實際大小估算時無限制消耗空間。
- 每 thread 首次確認避免沿用全域 outbound consent，但不同 thread 仍需各自取得同意。
- 暫時共用既有公司 gateway key 可減少部署變更，但共用代表撤銷與用量邊界共同承擔；任一方
  的撤銷需求或用量失控都可能影響另一方。key 不得因而出現在 Git、設定檔、skill 或 artifact。
- 同步全部 `work-helper` skills 可讓遠端 runtime 使用既有行為，但不能把 skill 同步誤當成
  授權；skills 不帶密鑰，filesystem、egress 與 agent role gate 仍是實際的權限邊界。
- Claude fallback 不再是方便、速度或第二意見的預設選項；需要留下具體 blocker，並遵守
  使用者同意與最小資料傳送的邊界。

## Open implementation items

- 定義非 native inbound 格式的受限制下載與檢查邊界，以及失敗時的使用者回覆。
- 補充 artifact 的大小上限、敏感資料界線與最小傳送範圍。
- 定義 outbound consent 的 thread 內記錄方式，以及同意失效或 thread 轉移時的處理。
- 定義本機 blocker 的可驗證記錄格式，讓 Claude fallback 的使用理由可被回顧。
