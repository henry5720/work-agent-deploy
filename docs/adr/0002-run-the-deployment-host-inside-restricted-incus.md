# Run the deployment host inside restricted Incus

Backlog agent的 deployment host使用 restricted Incus container，不直接使用實體 host的 Docker。Incus內再執行 systemd snapshot timer與 Compose；GitHub snapshot key、Slack secrets、Claude credential及repo snapshots都只存在Incus邊界內。這增加一層nested Docker與首次網路設定，換到不需給deployment identity實體host的sudo或Docker權限，且Docker邊界失守時仍停在Incus內。

## Consequences

- Incus instance必須允許nesting、開機自動啟動，並能對外連線到GitHub、Slack、Claude與套件來源。
- 實體host只需讓受限操作者管理自己的Incus project；不存放agent secrets或snapshot private key。
- 日常部署命令仍照runbook執行，但執行位置是Incus instance內的deployment user。
