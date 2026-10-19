## 仓库结构与复现材料

本仓库同时保存文章与可复现材料，便于按步骤核对配置：

| 路径 | 内容 |
| --- | --- |
| `app/web`、`app/api` | 示例应用源码与 Dockerfile；API 提供 `/healthz` 与 `/db-check` |
| `app/Jenkinsfile` | Git → 构建 → ACR → ACK 流水线，含参数化 deploy / rollback |
| `deploy/` | Web、API 的 Deployment 与 Service，MySQL 的 StatefulSet 与 headless Service |
| `manifests/monitoring/` | Prometheus、Alertmanager、Grafana、node-exporter、kube-state-metrics 与企业微信转发器 |
| `manifests/rbac/` | Jenkins 发布使用的 ServiceAccount、Role、RoleBinding，仅授予 get/list/watch/patch/update |
| `manifests/ingress/` | 按域名与按路径的 Ingress 示例 |
| `scripts/ack-inspect.sh` | 只读巡检脚本：节点状态、异常 Pod、重启次数、副本偏差与入口连通性 |

**脱敏说明**

- 镜像仓库主机以 `crpi-xxxxxxxxxxxx` 占位，使用时替换为实际 ACR 实例域名；命名空间沿用文中示例。
- 云账号 ID、RAM 用户名、节点私网地址、EIP 与企业微信 webhook key 均已移除或替换。
- 企业微信 webhook 由 Secret `wecom-webhook` 注入，仓库不保存任何密钥。
- `acr-pull`、`mysql-secret`、`mysql-initdb` 等对象需在集群内单独创建，仓库仅引用对象名。