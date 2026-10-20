# 阿里云 ACK 托管集群实战：架构规划与 CI/CD 全流程交付

> 本文记录在阿里云容器服务 Kubernetes 版（ACK）上完成的一次完整交付实验：部署由静态 Web、API 与 MySQL 组成的三层应用，并建立 Git → Jenkins → ACR → ACK 的自动化发布链路。
> 内容以架构设计说明与可复现的操作步骤为主，不包含验收截图；命令与参数按实验环境整理，其他环境需按实际取值调整。

- **关键词**：ACK、ACR、Jenkins、ingress-nginx、EIP、NodePort、StatefulSet、PVC、CI/CD、云原生
- **集群版本**：Kubernetes 1.36.2-aliyun.1 / containerd 2.3.4 / Terway
- **适用范围**：个人学习实验，预算上限 300 元；计算资源采用抢占式实例，入口采用自建 ingress-nginx

## 目录

- [1. 项目背景与目标](#1-项目背景与目标)
- [2. 整体架构](#2-整体架构)
- [3. 组件清单与作用](#3-组件清单与作用)
- [4. 环境准备](#4-环境准备)
- [5. 具体步骤](#5-具体步骤)
- [6. 常见故障与处理方法](#6-常见故障与处理方法)
- [7. 成本控制实践](#7-成本控制实践)
- [8. 结论与后续工作](#8-结论与后续工作)
- [9. 参考资料](#9-参考资料)

---

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

---

## 1. 项目背景与目标

### 1.1 背景

常见的 Kubernetes 入门实验通常止步于单机 minikube 或 kind 环境。实际交付流程包含以下四个环节，与入门实验差异较大：

- 集群由云厂商托管（ACK、EKS、TKE 等），不通过 kubeadm 自行初始化；
- 镜像经镜像仓库分发（ACR、Harbor 等），不在本地构建后直接使用；
- 发布由 CI 服务器自动执行，不依赖人工 kubectl apply；
- 应用为有状态（数据库）与无状态（API、前端）混合架构，而非单一 nginx。

本实验按上述四个环节组织，覆盖从代码提交到公网访问的完整链路，并在每个阶段记录设计依据、成本构成与常见故障。

### 1.2 项目目标

| # | 目标 | 说明 |
|---|---|---|
| 1 | 三层应用上线 | 静态 Web + API + MySQL，MySQL 数据落云盘可持久 |
| 2 | 公网入口配置 | 用域名 + 路径路由访问，**不为应用入口额外买负载均衡** |
| 3 | 交付自动化 | `git push` 后自动构建镜像、自动滚动发布，并支持一键回滚 |
| 4 | 成本可控 | 总预算 300 元，全部资源可随时整体释放 |
| 5 | 可复现 | 每个阶段都有脚本 / 清单归档，能照着再搭一遍 |

### 1.3 边界与约束

| 约束 | 具体口径 |
|---|---|
| 预算 | 300 元红线，全程按「窗口制」推进（阶段之间可整体释放） |
| 规模 | 2 个工作节点，分处两个可用区 |
| 集群形态 | ACK **托管集群·基础版**（免集群管理费，官方定位「个人学习或测试」） |
| 入口方案 | 不使用 SLB / ALB / NLB，自建 ingress-nginx |
| 出网方案 | 不创建 NAT 网关，节点默认无主动出网能力 |
| 项目定位 | 个人学习项目，**不包装成企业生产环境** |

---

## 2. 整体架构

### 2.1 架构全景图

![ACK-01-架构总览.png](images/ACK-01-架构总览.png)

*云资源骨架 + 集群内工作负载：EIP 只绑 j 区节点，两个节点分处两个可用区，MySQL 数据落 ESSD 云盘。*

![ACK-09-交付与运行拓扑.png](images/ACK-09-交付与运行拓扑.png)

*交付与运行拓扑：上半部分是 CI/CD 链路（本机 → Gitee → Jenkins → ACR），下半部分是集群内的入口与工作负载（ingress-nginx → Service → ack-web / ack-api → mysql-0）。*

### 2.2 架构图（Mermaid）

```mermaid
flowchart TB
    U["浏览器 / 用户"]

    subgraph CLOUD["阿里云 华东1（杭州）"]
        EIP["EIP 47.96.126.187<br/>按使用流量 5 Mbps"]
        SG["安全组<br/>放行 TCP 30080"]

        subgraph K8S["ACK 托管集群 · 基础版"]
            CP["托管控制面<br/>API Server / etcd / Scheduler"]
            subgraph ZJ["节点池1 · cn-hangzhou-j"]
                NJ["c7.xlarge 4C8G 抢占式"]
            end
            subgraph ZK["节点池2 · cn-hangzhou-k"]
                NK["c7.xlarge 4C8G 抢占式"]
            end
            ING["ingress-nginx DaemonSet"]
            WEB["ack-web ×2"]
            API["ack-api ×2"]
            DB["mysql-0 + PVC 20Gi"]
        end

        ACR["ACR 个人版<br/>命名空间 yunshiyan"]
        DISK["ESSD 云盘 20Gi"]
    end

    subgraph CICD["交付链路"]
        GIT["Gitee 私有仓库"]
        JEN["Jenkins 2.580.1<br/>独立 ECS"]
    end

    DEV["本机开发环境"]
    DEV --> GIT
    GIT -->|轮询 SCM| JEN
    JEN --> ACR
    JEN --> API
    ACR --> WEB
    ACR --> API
    ACR --> DB
    U --> EIP --> SG --> ING
    ING --> WEB
    ING --> API
    API --> DB
    DB --> DISK
    NJ -.-> ING
    NK -.-> ING
```

### 2.3 分层解读

系统按职责划分为三层：

**第一层：接入层 —— 让外网能进来**

集群内部的 Pod 只有内网 IP，外网天然访问不到。要让外部访问，缺的是「一个固定公网 IP」+「一个能把请求分发给不同服务的七层代理」。

这里的做法是：EIP（固定公网 IP）→ 节点 NodePort 30080 → ingress-nginx（七层代理）→ 按域名 / 路径分流到不同 Service。

采用该方案而不购买 SLB，原因有两点：一是成本，SLB、ALB、NLB 均为独立计费项；二是可控性，自建 Ingress 控制器的配置、日志与排障均在实验范围内。

**第二层：编排层 —— 让服务稳定地跑起来**

这一层是纯粹的 Kubernetes 对象设计：

- 无状态的 Web / API 用 **Deployment**：要副本数、要滚动更新、要自动重建；
- 有状态的 MySQL 用 **StatefulSet**：要有稳定的网络标识（`mysql-0.mysql.demo`）和稳定的存储卷；
- 数据用 **PVC** 声明，由 StorageClass 自动创建云盘，Pod 重建后数据还在。

**第三层：交付层 —— 让代码自动上线**

这一层是 CI/CD：代码放 Gitee，Jenkins 监听推送，构建镜像推到 ACR，再用最小权限账号把集群里的镜像版本改掉，触发 Deployment 滚动更新。

该层的设计重点是权限最小化：Jenkins 在集群内以 ServiceAccount 身份运行，仅可修改 Deployment 与读取 Pod，不能删除资源、读取 Secret 或查看节点信息。即使 Jenkins 被攻破，影响范围也限于 demo 命名空间的发布操作。

### 2.4 两条核心链路

**① 用户访问链路（自外向内）**

![ACK-02-用户访问链路.png](images/ACK-02-用户访问链路.png)

*从浏览器到数据库：公网入口六跳 + 域名/路径分流规则 + 数据落盘链路。*

| 步骤 | 发生了什么 | 关键点 |
|---|---|---|
| 1 | 浏览器请求 `lab.local` | 本机 hosts 把域名指向 EIP |
| 2 | EIP `47.96.126.187` 收到请求 | EIP 绑在 j 区节点上 |
| 3 | 安全组放行 TCP 30080 | 只需放行这一个端口 |
| 4 | 流量进入节点的 NodePort 30080 | `externalTrafficPolicy: Local` |
| 5 | 转给**本节点**上的 ingress-nginx Pod | 这正是必须用 DaemonSet 的原因 |
| 6 | 控制器按 host / path 匹配 Ingress 规则 | 三条规则分别指向 web / api |
| 7 | 请求到达对应 Service，再转发到 Pod | ClusterIP 做负载均衡 |
| 8 | API 访问 MySQL，数据落到云盘 | 数据持久化 |

**② 代码发布链路（自内向外）**

![ACK-05-交付流水线.png](images/ACK-05-交付流水线.png)

*七步主链路：git push → Gitee → Jenkins 轮询 → 构建 → 入库 ACR → 发布 → 滚动更新，并带一键回滚分支。*

| 步骤 | 发生了什么 | 关键点 |
|---|---|---|
| 1 | 本机 `git push` 到 Gitee | 私有仓库 |
| 2 | Jenkins **轮询 SCM**，发现 Gitee 上有新提交 | 控制器只监听回环地址，收不到外网 Webhook，因此用轮询 |
| 3 | Jenkins 拉代码（SSH 部署密钥） | 凭据存在 Jenkins 里 |
| 4 | `docker build` 构建镜像 | 必须带 `--provenance=false --sbom=false` |
| 5 | `docker login` + `docker push` 到 ACR | 先 login 再 build 之前也要 login（拉基础镜像） |
| 6 | `kubectl` 用 jenkins-deployer 身份改镜像版本 | 只能 patch，不能 delete |
| 7 | Deployment 滚动更新（maxUnavailable=0） | 保证更新过程中服务不中断 |
| 8 | 新 Pod 从 ACR 的 **VPC 内网地址**拉镜像 | 走内网，快且不计流量费 |

### 2.5 关键设计决策

| 决策点 | 采用方案 | 未采用方案 | 代价与对冲手段 |
|---|---|---|---|
| 集群版本 | ACK 托管集群**基础版** | Pro 版约 0.64 元/时（≈460 元/月），直接吃掉预算 | 基础版无 SLA，适合学习场景 |
| 节点计费 | 全**抢占式**实例 | 按量约 0.8 元/时/台，两台每天多花约 30 元 | 可能被回收；数据落云盘、节点池自动补齐 |
| 节点规格 | 4 vCPU / 8 GiB | 2 核机型受「低规格配额」限制，4C4G 主流无库存 | 单台成本略高，但可稳定创建 |
| 网络 | 不建 NAT 网关 | NAT 约 4.7 元/天 | 节点无主动出网，只能走内网端点 / EIP |
| 应用入口 | EIP + NodePort + Ingress | SLB / ALB / NLB 均为额外计费项 | 需自己维护控制器 |
| Ingress 实现 | **自建** ingress-nginx | ACK 组件的入口配置默认会创建 NLB 实例（付费）；且上游已停止维护 | 需要自己改写官方清单并处理镜像转存 |
| 镜像仓库 | ACR 个人版（免费） | 企业版按量计费 | 个人版不支持免密拉取，需 imagePullSecrets |
| 数据库 | 集群内 StatefulSet | RDS 成本高，且失去练习持久化的机会 | 需要自己做备份恢复演练 |
| Jenkins 部署 | 独立 ECS，**仅监听回环** | 直接暴露 8080 到公网风险高 | 需通过 SSH 隧道访问 |
| 发布权限 | 专用 ServiceAccount | 用主账号 AK 权限过大 | 需要维护 RBAC 清单 |
| 监控 | 自建 kube-prometheus-stack | 云监控高级功能按量计费 | 需要自己规划存储与告警链路 |

---

## 3. 组件清单与作用

### 3.1 阿里云侧组件

| 组件 | 技术本质 | 在本项目中的作用 |
|---|---|---|
| VPC 专有网络 | 租户级隔离的虚拟网络 | 划定整个实验的网络边界（`vpc-bp1po3ej0azh2fmf2fr40`） |
| 交换机 vSwitch | VPC 在某个可用区内的子网 | 为节点和 Pod 分配 IP（j 区 `vsw-bp1qlv3mtzsf59ypxav13`） |
| ECS 实例 | 挂载在 vSwitch 上的虚拟机 | 作为工作节点承载所有业务 Pod |
| 抢占式实例 | 竞价型实例，价格低但可能被回收 | 把节点成本压到按量的 1/5 |
| ACK 托管集群·基础版 | 由阿里云托管的 Kubernetes 控制面 | 免去 etcd / API Server 运维，管理费 ¥0 |
| Terway | ACK 的网络插件（CNI） | 为 Pod 分配 IP 并转发 Pod 网络流量 |
| CoreDNS + NodeLocal DNSCache | 集群内 DNS 服务 | 让 `mysql.demo` 这类 Service 名可解析 |
| CSI 存储插件 | 云盘对接 Kubernetes 的驱动 | PVC 声明后自动创建并挂载 ESSD 云盘 |
| CLB（私网） | 传统型负载均衡 | 托管集群自带，用于 API Server 的私网接入 |
| EIP 弹性公网 IP | 独立的公网 IPv4 地址 | 作为应用入口暴露到公网 |
| 安全组 | 有状态的主机级虚拟防火墙 | 只放行必要的 30080 端口 |
| ACR 个人版 | 容器镜像仓库 | 存放应用镜像与 ingress-nginx 镜像 |
| RAM | 阿里云权限体系 | 给运维动作分配最小权限（镜像转存只读） |
| ESSD 云盘 | 块存储 | MySQL 的 20 GiB 数据盘、节点系统盘 |
| Gitee | 代码托管平台 | 作为流水线的代码源头 |

### 3.2 Kubernetes 侧对象

| 对象 | 作用 | 本项目实例 |
|---|---|---|
| Namespace | 逻辑隔离，便于整体清理 | `demo`、`ingress-nginx` |
| Deployment | 无状态服务：副本数 / 滚动更新 / 自愈 | `ack-web` ×2、`ack-api` ×2 |
| StatefulSet | 有状态服务：稳定标识 + 稳定存储 | `mysql`（1 副本） |
| Service（ClusterIP） | 给一组 Pod 一个稳定的访问入口 | `ack-web:80`、`ack-api:8080` |
| Service（Headless） | 给 StatefulSet 提供稳定 DNS 名 | `mysql`（`clusterIP: None`） |
| Service（NodePort） | 把控制器暴露到每个节点端口 | `ingress-nginx-controller` 30080/30443 |
| DaemonSet | 保证每个节点都跑一个本地控制器 | `ingress-nginx-controller` |
| Ingress / IngressClass | 七层路由规则 | 三条规则（见 5.5） |
| PVC / PV / StorageClass | 持久化存储声明与实现 | 20 GiB ESSD 云盘 |
| Secret | 存放凭证 | `acr-pull`（拉镜像）、`mysql-secret` |
| ServiceAccount + Role + RoleBinding | 最小权限的集群内身份 | `demo/jenkins-deployer` |
| ValidatingWebhookConfiguration | 校验 Ingress 规则合法性 | ingress-nginx admission webhook |

### 3.3 流水线与工具链

| 工具 | 版本 / 形态 | 作用 |
|---|---|---|
| Jenkins | 2.580.1（独立 ECS） | 拉代码、构建镜像、推仓库、发起发布 |
| OpenJDK | 21 | Jenkins 2.580 要求 JDK 17 以上 |
| Gitee 私有仓库 | `ack-lab-app` | 代码源头 + Webhook 触发 |
| kubectl | v1.36.2 | 与集群版本对齐，避免 API 版本差异 |
| crane | v0.22.1 | 把公网镜像原样转存进 ACR |
| Playwright + Chrome | 本机 | 用于本地渲染校验（非交付物） |

---
## 4. 环境准备

### 4.1 资源规划矩阵
实验开始前先确定资源清单与计费方式，避免实施过程中追加资源导致预算失控。
动手之前先把要买的东西列清楚，避免边做边加资源（这是预算失控最常见的原因）。

| 类别 | 资源 | 规格 | 数量 | 计费方式 |
|---|---|---|---|---|
| 编排 | ACK 托管集群·基础版 | Kubernetes 1.36.2-aliyun.1 | 1 | 管理费 ¥0 |
| 计算 | ECS 节点（c7.xlarge） | 4 vCPU / 8 GiB + 40 GiB ESSD 系统盘 | 2 | 抢占式 |
| 网络 | VPC + 交换机 | 按可用区划分 | 1 + 2 | 免费 |
| 网络 | EIP（应用入口） | 按使用流量，峰值 5 Mbps | 1 | 按量 |
| 网络 | CLB（API Server 私网） | 托管集群自带 | 1 | 按量 |
| 存储 | ESSD 云盘（MySQL 数据） | 20 GiB | 1 | 按量 |
| 镜像 | ACR 个人版 | 命名空间 `yunshiyan` | 1 | 免费 |
| 构建 | Jenkins ECS | 独立实例，仅回环监听 | 1 | 按量（实验间隙可停机） |
| 代码 | Gitee 私有仓库 | `ack-lab-app` | 1 | 免费 |

**规划说明：**

1. **节点规格不低于 4 vCPU / 8 GiB。** 2 核规格受低规格配额限制，需单独申请；4 核 4 GiB 在主流机型上长期无库存，4 核 8 GiB 为可稳定创建的最低规格。
2. **节点分布于两个可用区。** 可用区具备独立的电力、网络与制冷设施，双可用区可将容灾范围从单机提升至机房级。
3. **仅保留一个 EIP。** 公网暴露面收敛到单一地址，其余节点不分配公网 IP。
4. **不创建 NAT 网关。** 可节省约 4.7 元/天；代价是节点不具备主动出网能力，镜像拉取需使用 VPC 内网端点或已转存至 ACR 的镜像。

### 4.2 账号与权限准备（RAM）

**权限原则：优先使用 RAM 子账号配合自定义策略，不使用主账号 AccessKey。**

| 用途 | 身份 | 权限范围 |
|---|---|---|
| 镜像转存（本机 crane） | RAM 子账号 | 自定义策略，仅 ACR 只读相关 Action |
| 集群内发布（Jenkins） | Kubernetes ServiceAccount | 仅 `demo` 命名空间，仅 get/list/watch/patch/update |
| 控制台运维 | 主账号 | 日常手工操作 |

**镜像转存仅需只读权限的原因**

转存方向为从公共镜像源读取、写入自有 ACR。写入自有 ACR 使用 ACR 登录凭证（docker login），读取源镜像本身不需要 RAM 权限；需要 RAM 授权的是访问 ACR 的 API（查询仓库、读取元数据）。因此为子账号授予 ACR 只读策略即可，凭证泄露时也仅具备读取能力。

**集群内发布不使用 AccessKey 的原因**

AccessKey 为账号级长期凭证，泄露即等同于账号失守。ServiceAccount 是集群内身份，可通过 RBAC 限定到具体命名空间、资源与动作，为云原生场景的标准做法。

### 4.3 本机工具链准备

在 Windows + PowerShell 环境下，需要准备以下工具（统一放在一个独立目录，避免污染系统环境）：

| 工具 | 版本 | 用途 |
|---|---|---|
| kubectl | v1.36.2 | 与集群版本对齐 |
| crane | v0.22.1 | 镜像转存（比 `docker pull/tag/push` 更适合多架构场景） |
| SSH 客户端 | Windows 自带 | 隧道访问 Jenkins |
| Gitee 仓库 | — | 代码托管 |

**kubeconfig 获取：** 在 ACK 控制台的「集群信息 → 连接信息」下载，或者在集群列表页点「配置 kubectl」。下载后放到用户目录下的 `.kube` 目录，通过 `--kubeconfig` 或 `KUBECONFIG` 环境变量指定。

验证连接：

```bash
kubectl --kubeconfig "$HOME/.kube/ack-cloud-lab.yaml" version
kubectl --kubeconfig "$HOME/.kube/ack-cloud-lab.yaml" get nodes -o wide
```

> **注意**：ACK 集群的 kubeconfig 里 context 名通常形如 `kubernetes-admin-<集群ID>`，切换集群时务必确认当前 context 正确，避免误操作到别的集群。

### 4.4 网络与域名准备

应用要用域名访问，而项目不打算为 DNS 解析付费，所以采用**本机 hosts 映射**的方式（实验演示已足够）：

```text
# C:\Windows\System32\drivers\etc\hosts
47.96.126.187  lab.local
47.96.126.187  api.lab.local
```

如果想让其他人也能访问，把域名解析到 EIP 即可，集群侧不需要任何改动（Ingress 是按 host 匹配的，与解析方式无关）。

### 4.5 成本估算

| 资源 | 单价 | 约合 |
|---|---|---|
| ACK 集群管理费（基础版） | ¥0 | ¥0 |
| Worker 节点 4C8G（抢占式）×2 | 0.15 ~ 0.16 元/时/台 | ≈7.5 元/天 |
| 系统盘 ESSD 40 GiB ×2 | 0.04 元/时/台 | ≈1.9 元/天 |
| API Server 私网 CLB | 0.147 元/时 + 0.049 元/LCU | ≈3.5 元/天 |
| EIP（按使用流量） | 0.02 元/时 + 0.8 元/GB | ≈0.5 元/天 |
| Jenkins ECS（按量） | 视规格 | ≈4 元/天 |
| **合计（全部在线）** | | **≈18 元/天** |

价格为控制台实测价，随地域与时间会变化。按 18 元/天计算，300 元预算大约可以支撑 **16 天**的连续在线时间。

---

## 5. 具体步骤

整个搭建过程按依赖关系分成 6 个阶段，**每个阶段都能独立验证、独立回滚**。这种「一步一验」的推进方式，是为了在出问题时能把故障范围锁定在一个阶段内。

![ACK-08-六阶段路线图.png](images/ACK-08-六阶段路线图.png)

*六个阶段的推进顺序与每阶段产出：底座 → 能力 → 仓库 → 应用 → 入口 → 自动化，后面的每一环都依赖前面那一环。*

| 阶段 | 目标 | 依赖 |
|---|---|---|
| 一 | 创建集群并完成基础验证 | 阿里云账号 |
| 二 | 扩展第二个可用区节点池 | 阶段一 |
| 三 | 建 ACR 并验证「集群能拉到私有镜像」 | 阶段一 |
| 四 | 部署应用（Web / API / MySQL） | 阶段三 |
| 五 | 配置公网入口 | 阶段四 |
| 六 | 配置自动化交付流水线 | 阶段三 + 阶段四 |

### 5.1 阶段一：创建 ACK 托管集群并完成基础验证

**目标**：拿到一个健康、可控、能连上的 Kubernetes 集群。

**操作：**

1. 控制台选择「ACK 托管集群 · 基础版」，地域华东1（杭州）。
2. 网络插件选 **Terway**；容器运行时默认 containerd。
3. 节点池：1 个节点池，规格 `c7.xlarge`（4C8G），系统盘 40 GiB ESSD，**计费方式选抢占式**。
4. 创建完成后，从「集群信息 → 连接信息」下载 kubeconfig。

**基础验证（这一步非常重要，不要跳过）：**

```bash
# 1. 版本是否对齐
kubectl version

# 2. 节点是否 Ready，并确认所在可用区
kubectl get nodes -o wide
kubectl get nodes -L topology.kubernetes.io/zone

# 3. 系统组件是否全部 Running（有 Pending 就要先查 Events）
kubectl get pods -n kube-system
kubectl get events -n kube-system --sort-by=.lastTimestamp | tail -20

# 4. 存储类是否存在（阶段四要用）
kubectl get storageclass

# 5. 节点资源是否达到预期
kubectl top nodes
```

**要关注的几个点：**

- **StorageClass 的回收策略**：ACK 默认 StorageClass 一般是 `Delete`，意味着**删除 PVC 就会释放云盘**、计费停止。这是省钱的关键，也是误删数据的风险点，必须提前知道。
- **系统 Pod 有 Pending**：说明资源不足或有调度约束，先在 `kube-system` 的 Events 里定位，不要带着问题往下走。
- **集群管理费**：基础版在账单里应显示为 ¥0，如果出现管理费要立刻确认集群规格是不是选错了。

### 5.2 阶段二：扩展第二个可用区节点池

**目标**：把集群从单可用区扩展为双可用区，为后续有状态服务落位做准备。

**操作：** 在集群的「节点池」页面新增一个节点池，规格与节点池 1 保持一致，**可用区选择不同的机房**（例如第一个是 `cn-hangzhou-j`，第二个选 `cn-hangzhou-k`）。

**验证：**

```bash
kubectl get nodes -L topology.kubernetes.io/zone
# 期望：两台节点分别落在两个不同的 zone
```

**分两次创建节点池的原因**

因为「一次只做一步」——先确认单节点集群完全正常，再加第二个节点池。这样如果加节点池失败，可以确定问题出在节点池配置本身，而不是集群创建参数里某个被掩盖的错误。这也是实际运维排障的常规思路：**让每次变更只引入一个变量**。

### 5.3 阶段三：ACR 镜像仓库与「拉取验证门」

**目标**：建好镜像仓库，并**单独验证**「集群能从私有仓库拉取镜像」这条链路。

**“拉取验证门”的含义**

镜像拉取是整个交付链路中最易出故障的环节。若直接部署应用而不单独验证，Pod 无法启动时将难以区分是**镜像拉取失败**、**应用配置错误**还是**流水线问题**。因此先用一个最小 nginx 镜像验证该链路，通过后再部署业务应用。

**操作步骤：**

**① 创建 ACR 个人版实例与命名空间**

在容器镜像服务控制台创建个人版实例，然后创建命名空间（本项目为 `yunshiyan`），再在命名空间下创建仓库。本项目共用到 5 个仓库：

| 仓库 | 用途 |
|---|---|
| `ack-web` | 前端应用镜像 |
| `ack-api` | 后端 API 镜像 |
| `mysql` | 数据库镜像（从 Docker Hub 转存） |
| `ingress-nginx` | Ingress 控制器镜像（从 registry.k8s.io 转存） |
| `ack-gate-nginx` | 「拉取验证门」用的最小镜像 |

**② 创建 RAM 子账号并授予 ACR 只读权限**

创建自定义策略，只授予 ACR 只读相关的 Action，绑定给专用子账号。这个账号的 AccessKey 只用于本机的镜像转存动作。

**③ 用 crane 把镜像转存进 ACR**

```bash
# 先做只读预校验：确认源镜像存在，并记录 digest
crane digest registry.k8s.io/ingress-nginx/controller:v1.15.1

# 转存（本机在公网侧，走 ACR 的公网域名推送）
crane copy registry.k8s.io/ingress-nginx/controller:v1.15.1 \
  crpi-xxxxxxxxxxxx.cn-hangzhou.personal.cr.aliyuncs.com/yunshiyan/ingress-nginx:controller-v1.15.1
```

> **注意公网域名与 VPC 域名的区别**：ACR 个人版会提供两个访问域名，一个是公网域名 `crpi-xxxx.cn-hangzhou.personal.cr.aliyuncs.com`，另一个是 VPC 内网域名 `crpi-xxxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com`（多一个 `-vpc`）。
> **本机转存使用公网域名**（本机位于公网侧），**集群内拉取必须使用 VPC 域名**（集群节点位于 VPC 内，使用公网域名将导致拉取失败）。该问题为实验中出现的第一个故障。

![ACK-03-ACR域名对比.png](images/ACK-03-ACR域名对比.png)

*同一份镜像、两个域名：本机转存走公网域名，集群拉取必须走 VPC 域名。*

**④ 在集群里创建拉取凭证**

```bash
kubectl -n demo create secret docker-registry acr-pull \
  --docker-server=crpi-xxxxxxxxxxxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com \
  --docker-username='<RAM用户名>' \
  --docker-password='<RAM密码>'
```

然后在 Pod 的 `imagePullSecrets` 里引用这个 Secret。**注意**：2024-09-09 之后新建的 ACR 个人版实例不支持免密拉取插件，所以 `imagePullSecrets` 是必须的，不能省。

**⑤ 部署最小验证 Pod**

```bash
kubectl -n demo apply -f acr-gate-nginx.yaml
kubectl -n demo get pods -o wide
```

**验证要点：**

- Pod 状态为 `Running`（不是 `ImagePullBackOff`）；
- `kubectl describe pod` 的事件里显示镜像是从 **VPC 域名**拉取的；
- 如果失败，第一件事就是确认镜像地址是不是漏了 `-vpc`。

**⑥ 顺带验证集群内 DNS 与跨节点连通性**

这个「门」里还可以顺手把后面的依赖一起验掉：

```bash
# 集群内 DNS 是否正常
kubectl -n demo run dnstest --rm -it --image=<ACR-VPC地址>/yunshiyan/ack-gate-nginx:v1 -- \
  sh -c 'nslookup mysql.demo; nslookup kubernetes.default'

# 跨节点访问是否正常（用 Service 或 Pod IP 互访）
kubectl -n demo exec -it <pod-a> -- sh -c 'wget -qO- http://<service-or-pod>'
```

这样在进入阶段四之前，「拉镜像 / DNS 解析 / Service 连通 / 跨节点通信」四件事已经被验证过了，后面出问题的概率会大幅下降。

### 5.4 阶段四：应用部署（Web / API / MySQL 持久化）

**目标**：把三层应用跑起来，数据落云盘。

**操作顺序**：先数据库，后后端，再前端（依赖顺序）。

**① 创建命名空间与密码 Secret**

```bash
kubectl create namespace demo
kubectl -n demo create secret generic mysql-secret \
  --from-literal=root-password='<root密码>' \
  --from-literal=app-password='<应用账号密码>'
```

**② 部署 MySQL（Headless Service + StatefulSet + PVC）**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: demo
  labels:
    app: mysql
spec:
  clusterIP: None          # Headless：不分配 ClusterIP，直接返回 Pod IP
  selector:
    app: mysql
  ports:
  - name: mysql
    port: 3306
    targetPort: 3306
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: demo
spec:
  serviceName: mysql        # 绑定 Headless Service，提供稳定 DNS 标识
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      automountServiceAccountToken: false
      imagePullSecrets:
      - name: acr-pull
      containers:
      - name: mysql
        image: crpi-xxxxxxxxxxxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com/yunshiyan/mysql@sha256:62fb722c...
        args:
        - --character-set-server=utf8mb4
        - --collation-server=utf8mb4_unicode_ci
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: root-password
        - name: MYSQL_DATABASE
          value: demo
        resources:
          requests: { cpu: 250m, memory: 512Mi }
          limits:   { cpu: "1",  memory: 1Gi }
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
        startupProbe:                 # MySQL 首次初始化可能较慢，用 startupProbe 兜住
          tcpSocket:
            port: 3306
          periodSeconds: 5
          failureThreshold: 60
        readinessProbe:
          exec:
            command: ["sh", "-c", "mysqladmin ping -h 127.0.0.1"]
```

`volumeClaimTemplates` 部分声明 20 GiB 的 PVC，StorageClass 会自动创建一块云盘。

**③ 部署 API（Deployment + ClusterIP Service）**

关键片段：

```yaml
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0       # 更新过程中不允许副本数下降
      maxSurge: 1             # 允许临时多起一个
  template:
    spec:
      imagePullSecrets:
      - name: acr-pull
      containers:
      - name: api
        image: crpi-xxxxxxxxxxxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com/yunshiyan/ack-api@sha256:2c57bfca...
        env:
        - name: DB_HOST
          value: mysql           # 直接用 Service 名，集群内 DNS 解析
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: app-password
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        readinessProbe:
          httpGet: { path: /healthz, port: http }
        livenessProbe:
          httpGet: { path: /healthz, port: http }
```

**④ 部署 Web（Deployment + ClusterIP Service）**

结构与 API 相同，`maxUnavailable: 0`，暴露 80 端口。

**几个刻意的设计点：**

| 设计 | 原因 |
|---|---|
| 镜像用 `@sha256:` **digest** 固定，不用 `:v1` tag | tag 可以被覆盖，digest 不会；出问题时能精确知道跑的是哪个版本 |
| `maxUnavailable: 0` | 保证滚动更新期间服务不中断（2 副本时先起新的再停旧的） |
| `automountServiceAccountToken: false` | 应用不需要访问 API Server，就不该挂载 token |
| `runAsNonRoot` + `drop: ALL` | 最小权限运行，降低容器逃逸风险 |
| startupProbe / readinessProbe 分开 | 启动慢 ≠ 服务异常，用 startupProbe 兜启动、readiness 判断能否接流量 |

**⑤ 验证**

```bash
kubectl -n demo get pods -o wide
kubectl -n demo exec -it deploy/ack-api -- sh -c 'wget -qO- http://localhost:8080/db-check'
# 期望输出里能看到 MySQL 版本号，说明 Web → API → MySQL → 云盘整条链路打通
```

**阶段注意事项：** StatefulSet 遇到未 Ready 的 Pod 不会自动重建，将保持等待状态。此时需手动删除该 Pod 触发重建：

```bash
kubectl -n demo delete pod mysql-0
```

---
### 5.5 阶段五：集群入口配置（EIP、NodePort 与 Ingress）

**目标**：让公网用域名访问到集群内的服务，且不新增付费的负载均衡。

**先做两个选型判断：**

**决策一：入口实现方式**

| 方案 | 成本 | 特点 |
|---|---|---|
| SLB / ALB / NLB | 按规格 + 流量计费，是独立账单项 | 开箱即用，运维负担低 |
| **EIP + NodePort + Ingress** | 只有 EIP 的持有费和流量费 | 需要自己维护控制器，但学习价值最高 |

本项目选后者：应用入口不额外付费，同时把「七层入口」这一环做成可控、可观察的对象。

**决策二：Ingress 控制器来源**

查官方文档后确认两点：一是 ACK 侧新装 Ingress 组件时**默认会创建 NLB 实例**（付费资源），二是 ingress-nginx 上游已停止维护、ACK 也同步停止维护。因此改为**自建 ingress-nginx**：用官方 baremetal 清单（不依赖云厂商 LoadBalancer 实现的版本）部署，自己接管镜像、端口和参数。

**操作步骤：**

**① 把 ingress-nginx 镜像转存进 ACR**

```bash
# 控制器镜像
crane copy registry.k8s.io/ingress-nginx/controller:v1.15.1 \
  crpi-xxxxxxxxxxxx.cn-hangzhou.personal.cr.aliyuncs.com/yunshiyan/ingress-nginx:controller-v1.15.1

# admission webhook 用的证书生成镜像
crane copy registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9 \
  crpi-xxxxxxxxxxxx.cn-hangzhou.personal.cr.aliyuncs.com/yunshiyan/ingress-nginx:webhook-certgen-v1.6.9
```

转存后记录 digest，后续清单里按 digest 固定版本：

```text
controller-v1.15.1     sha256:de8fd8f1def14ed36f59c9838bd3c920ecb01754072e3e9f10832d62ef876cb8
webhook-certgen-v1.6.9 sha256:f0dd00beb0fa11f65e81a0fcc09dd343d71d4aaa8875a2bd93f664883d481331
```

**② 改写官方清单**

下载官方的 baremetal 部署清单后，用脚本做改写（脚本化改写的好处是**可复现、可审计**，而不是手工在几千行 YAML 里改）。改写点如下：

| 改写项 | 原值 | 改后 | 原因 |
|---|---|---|---|
| 控制器镜像 | `registry.k8s.io/...` | ACR 的 **VPC 域名**地址 | 集群内拉取必须走内网 |
| webhook 镜像 | `registry.k8s.io/...` | 同上 | 同上 |
| Service 类型与端口 | `NodePort`（端口由集群随机分配） | `NodePort` + 固定 30080 / 30443 | 配合 EIP 使用，端口必须固定 |
| 流量策略 | 默认（Cluster） | `externalTrafficPolicy: Local` | 保留真实客户端 IP，少一跳转发 |
| 状态地址 | 默认上报 Pod IP | `--publish-status-address=<EIP>` | 让 Ingress 状态显示真实入口 |
| 资源限制 | 无 | `limits: 1 CPU / 512Mi` | 避免控制器抢占节点资源 |

**③ 创建命名空间与拉取凭证**

```bash
kubectl create namespace ingress-nginx
kubectl -n ingress-nginx create secret docker-registry acr-pull \
  --docker-server=crpi-xxxxxxxxxxxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com \
  --docker-username='<RAM用户名>' \
  --docker-password='<RAM密码>'
```

**④ 部署控制器**

```bash
kubectl apply -f deploy-ingress-nginx-v1.yaml
kubectl -n ingress-nginx get pods -o wide
kubectl get ingressclass          # 期望看到 nginx
```

**⑤ 确认入口 Service 是固定 NodePort**

改写后的清单里，Service 已经是 `NodePort` 类型并固定了两个端口，部署完先确认一下：

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,LOCAL:.spec.externalTrafficPolicy,PORTS:.spec.ports[*].nodePort
# 期望：NodePort / Local / 30080,30443
```

如果清单里遗漏了这两项（例如直接沿用了上游默认值），用 merge patch 补上：

```bash
kubectl -n ingress-nginx patch svc ingress-nginx-controller --type=merge -p '{
  "spec": {
    "type": "NodePort",
    "externalTrafficPolicy": "Local",
    "ports": [
      {"name": "http",  "port": 80,  "targetPort": 80,  "nodePort": 30080, "protocol": "TCP"},
      {"name": "https", "port": 443, "targetPort": 443, "nodePort": 30443, "protocol": "TCP"}
    ]
  }
}'
```

**⑥ 确认 Ingress 状态显示的是真实入口地址**

`--publish-status-address` 在改写清单时已经写进控制器参数了，这里做一次确认。如果 `kubectl get ingress` 看到的 `ADDRESS` 是控制器 Pod 的 IP 而不是公网 EIP，说明参数没生效，用下面的 patch 补上：

```bash
kubectl -n ingress-nginx get deploy ingress-nginx-controller -o yaml | grep publish-status

kubectl -n ingress-nginx patch deploy ingress-nginx-controller --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--publish-status-address=47.96.126.187"}]'
```

> ⚠️ 这个 patch 会触发控制器**滚动重启**。重启带来的调度变化，正是下一节要讲的「入口中断」问题的触发条件——所以请把这次改动和 DaemonSet 改造连续做完，不要停在中间状态。

**⑦ 配置安全组**

在 EIP 所绑节点的安全组入方向放行 TCP 30080（演示期源地址可设为 `0.0.0.0/0`，生产环境应限制来源）。**只需要放行这一个端口**，30443 后续做 HTTPS 时再放行。

**⑧ 创建 Ingress 路由规则**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ack-web-ingress
  namespace: demo
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
  - host: lab.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ack-web
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ack-api-ingress
  namespace: demo
spec:
  ingressClassName: nginx
  rules:
  - host: api.lab.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ack-api
            port:
              number: 8080
---
# 路径路由演示：lab.local/api/xxx -> ack-api 的 /xxx
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ack-path-routing-demo
  namespace: demo
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - host: lab.local
    http:
      paths:
      - path: /api(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: ack-api
            port:
              number: 8080
```

第三条规则是**路径重写**的经典写法：

- 正则 `/api(/|$)(.*)` 里，`(.*)` 是第二个捕获组；
- `rewrite-target: /$2` 表示把匹配到的请求重写成「第二个捕获组的内容」；
- 于是 `lab.local/api/db-check` 会被转发到 `ack-api` 的 `/db-check`。

**验证：**

```bash
# 从本机（公网侧）验证
curl -I http://lab.local/            # 期望 200
curl -I http://api.lab.local/        # 期望 200
curl -I http://lab.local/api/db-check
curl -I http://not-exist.local/      # 期望 404（域名没配规则）

# 集群内验证（绕过公网，直接测节点 NodePort）
kubectl -n ingress-nginx exec -it <controller-pod> -- sh -c \
  'curl -s -o /dev/null -w "%{http_code}\n" http://localhost/'
```

同时看控制器日志，确认记录的是**真实客户端公网 IP**（而不是节点 IP）——这证明 `externalTrafficPolicy: Local` 生效了。

**关键变更：控制器由 Deployment 改为 DaemonSet**

按上面的步骤配好之后，一次「滚动重启」引发了**入口完全中断**：公网访问全部返回 `000`（连不上），但集群内部访问正常。

原因链条是这样的：

1. `externalTrafficPolicy: Local` 的含义是：节点只把流量转发给**运行在本节点上**的 Pod，不做二次转发；
2. EIP 是绑在 **j 区节点**上的，所以只有 j 区节点收到公网流量；
3. 滚动重启后，两个控制器 Pod 被调度到了 **k 区节点**；
4. 于是 j 区节点上没有本地控制器 Pod，`Local` 策略无处可转 → 公网请求全部失败。

集群内实测也印证了这一点：从 j 区节点访问 NodePort 超时，从 k 区节点访问正常。

![ACK-04-入口中断复盘.png](images/ACK-04-入口中断复盘.png)

*事故时间线 + 修复前后对比：Deployment 时副本可能全落 k 区，改成 DaemonSet 后每节点必有本地控制器。*

**这是一个「结构性」问题，不是配置错误**——只要控制器是 Deployment，副本就可能落在任意节点上。所以解法不是去调参数，而是**改变部署形态**：把控制器从 Deployment 改成 **DaemonSet**，让每个节点上都必然有一个本地控制器 Pod。

```yaml
kind: DaemonSet          # 原为 Deployment
# replicas 字段移除：副本数由节点数决定
```

改完之后，无论 Pod 怎么重建、节点怎么分布，收到流量的那个节点上一定有本地控制器，问题被结构性消除。

**结论**：`externalTrafficPolicy: Local` + EIP 绑单节点，这个组合必须配合「每个节点都有本地入口 Pod」才能成立。如果不想引入 DaemonSet，另一条路是把 `externalTrafficPolicy` 改回 `Cluster`（代价是丢失真实客户端 IP，且多一跳）。

### 5.6 阶段六：CI/CD 流水线（Gitee + Jenkins + ACR + ACK）

**目标**：`git push` 后自动构建、自动发布，并支持一键回滚。

![ACK-07-交付链路流程图.png](images/ACK-07-交付链路流程图.png)

*一次提交的完整流程：七个主要环节与两处分支（发布成功 / 异常回滚），标注了各环节的常见问题。*

**① 准备代码仓库**

在 Gitee 建私有仓库（本项目为 `ack-lab-app`），包含三个部分：

```text
ack-lab-app/
├── web/            # 前端 Dockerfile + 静态页面
├── api/            # API Dockerfile + app.py
└── Jenkinsfile     # 流水线定义
```

**② 部署 Jenkins（独立 ECS）**

Jenkins 放在一台独立 ECS 上，与集群分离——原因是构建任务非常吃 CPU 和内存，如果放在集群节点上会挤占业务资源，而且构建镜像需要 Docker，与节点的 containerd 运行时混用会带来额外复杂度。

安装要点：

| 项目 | 配置 |
|---|---|
| JDK | OpenJDK 21（Jenkins 2.580 要求 JDK 17+） |
| 部署方式 | 下载 war 包 + systemd 托管 |
| 监听地址 | **仅 127.0.0.1**（不监听公网） |
| 插件 | 61 个（Git、Pipeline、Credentials、Gitee 等） |

**③ 安全访问方式：SSH 隧道**

Jenkins **不监听公网**，只监听本机回环地址，通过 SSH 隧道访问：

```bash
# 本机执行：把远端 8080 映射到本机 8080
ssh -i <私钥路径> -L 8080:127.0.0.1:8080 root@<ECS公网IP>
# 然后浏览器访问 http://127.0.0.1:8080
```

Jenkins Web 界面不对公网暴露，可避免扫描与暴力破解。**代价是必须通过 SSH 访问该主机**，因此需妥善保管私钥。

**④ 初始化 Jenkins**

Jenkins 首次启动会进入「安装向导」，在向导完成之前，通过 REST API 做的大多数写操作都会被拒绝（返回 500）。所以用一段幂等的 Groovy 脚本放进 `init.groovy.d`，让它启动时自动完成两件事：

1. 把安装状态标记为「已完成」；
2. 创建本地管理员账号，并设置「登录后全权、匿名无权限」。

**⑤ 配置凭据**

| 凭据 ID | 类型 | 用途 |
|---|---|---|
| `gitee-deploy-key` | SSH 私钥 | 拉取 Gitee 私有仓库 |
| `acr-credential` | 用户名密码 | 登录并推送 ACR |
| `ack-kubeconfig` | 文件 | 访问 ACK 集群 |

> **注意**：粘贴 SSH 私钥文本时，首行不得包含前导空行或空格，否则凭据校验将失败。

**⑥ 在集群里创建最小权限身份**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-deployer
  namespace: demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-deployer
  namespace: demo
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "services"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create", "get"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch", "patch", "update"]   # 注意：没有 delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-deployer
  namespace: demo
subjects:
  - kind: ServiceAccount
    name: jenkins-deployer
    namespace: demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-deployer
---
# 生成长期 token（1.24 之后 Secret 方式需显式创建）
apiVersion: v1
kind: Secret
metadata:
  name: jenkins-deployer-token
  namespace: demo
  annotations:
    kubernetes.io/service-account.name: jenkins-deployer
type: kubernetes.io/service-account-token
```

**这个 Role 的设计意图：**

- ✅ 能看 Pod 和日志 → 发布后可以自检；
- ✅ 能 patch Deployment → 能改镜像版本、能触发回滚；
- ❌ **不能 delete** → 即使流水线被恶意利用，也删不掉业务负载；
- ❌ **不能读 Secret** → 拿不到数据库密码、拉镜像凭证；
- ❌ **不能看 nodes** → 看不到节点信息，攻击面进一步收敛；
- ❌ **只限 `demo` 命名空间** → 碰不到 `kube-system`。

**⑦ 创建流水线任务**

Job 类型选 **Pipeline from SCM**，配置如下：

| 配置项 | 值 |
|---|---|
| SCM | Git |
| 仓库地址 | `git@gitee.com:<用户名>/ack-lab-app.git` |
| 凭据 | `gitee-deploy-key` |
| 分支 | `*/master` |
| 脚本路径 | `Jenkinsfile` |
| 参数 | `ACTION`（可选 `deploy` / `rollback`） |

**⑧ Jenkinsfile 的核心阶段**

| 阶段 | 动作 | 关键点 |
|---|---|---|
| Checkout | 拉取代码 | 用 SSH 部署密钥 |
| Build | `docker build` 构建 web / api 镜像 | 必须带 `--provenance=false --sbom=false` |
| Push | `docker login` + `docker push` 到 ACR | login 必须在 build 之前（要拉基础镜像） |
| Deploy | `kubectl set image` / `kubectl patch` | 用 jenkins-deployer 的 token |
| Rollback | `kubectl rollout undo` | `ACTION=rollback` 时走这条路径 |

> **关于 `--provenance=false --sbom=false`**：新版 buildx 默认会给镜像附加 provenance 和 SBOM 元数据（生成 OCI index 多架构清单）。部分镜像仓库对这个格式支持不完整，会出现「推送成功但拉取失败」。加上这两个参数可以生成最通用的单架构镜像格式，兼容性最好。

**⑨ 配置自动触发：用轮询而不是 Webhook**

这里有一个容易被忽略的联动：前一步为了安全，把 Jenkins 限制成**只监听 127.0.0.1**，那么 Gitee 的 Webhook 就**根本送不进来**（公网无法访问到 Jenkins 的 8080）。

所以自动触发改用 **SCM 轮询（Poll SCM）**：在 Job 里配置定时轮询 Gitee 仓库，发现新提交就自动构建。

| 方案 | 可行性 | 说明 |
|---|---|---|
| Gitee Webhook | ❌ 不适用 | Jenkins 未监听公网，Webhook 送不进来；要开放则需牺牲前面做的安全设计 |
| **SCM 轮询** | ✅ 采用 | Jenkins 主动出网轮询，不需要任何入向端口 |
| 手动触发 | ✅ 保留 | 发布 / 回滚演练时使用 |

这也是一种典型的工程取舍：**安全性和「实时性」往往不能同时最优**。轮询会带来最长一个轮询周期的延迟，但换来了不必暴露管理界面。生产环境更常见的做法是把 Webhook 打到一个内网网关或反向代理上，再由代理转发给 Jenkins。

**⑩ 验证流水线**

| 场景 | 操作 | 期望结果 |
|---|---|---|
| 正常发布 | 改一次代码并 push | 下一个轮询周期内 Job 自动触发，构建成功，集群里 Pod 镜像版本更新，页面内容变化 |
| 回滚 | 以 `ACTION=rollback` 触发 | 镜像回退到上一版本，服务恢复正常 |

---
### 5.7 阶段七：监控与告警（Prometheus + Grafana + Alertmanager）

**目标**：让集群"出问题能被发现，并且主动通知到人"。

前面六个阶段解决的是"能不能跑通"，这一阶段解决的是"跑挂了谁知道"。没有监控的集群，故障只能靠用户报障发现。

#### ① 组件选型依据

| 组件 | 职责 | 一句话理解 |
|---|---|---|
| node-exporter | 采集节点级指标（CPU、内存、磁盘、网络） | 每台节点一个，DaemonSet |
| kube-state-metrics | 把 Kubernetes 对象状态翻译成指标 | 回答"这个 Deployment 期望几个、实际几个" |
| Prometheus | 定时抓取、存储、按规则计算 | 既是数据库，也是计算引擎 |
| Alertmanager | 分组、去重、静默、路由 | 告警的调度中心 |
| wecom-adapter | 把 Alertmanager 的 JSON 转成企业微信格式 | 翻译官 |
| Grafana | 可视化 | 看板 |

一个容易混淆的点：**node-exporter 看的是机器，kube-state-metrics 看的是对象**。前者回答"这台机器 CPU 用了多少"，后者回答"这个 Deployment 应该有几个 Pod、现在有几个"。两类指标互补，不能互相替代。

#### ② 数据流向

```text
节点内核 ─────→ node-exporter ──┐
                              ├──→ Prometheus（每 15 秒抓一次，写入 TSDB）
API Server ──→ kube-state-metrics ──┘
                                      │
                            每 15 秒执行一次告警规则
                                      ↓
                              Alertmanager（分组 / 去重 / 静默）
                                      ↓
                              wecom-adapter（转成企业微信消息体）
                                      ↓
                              企业微信群机器人
```

这条链路上任何一个环节断了，手机上都不会有消息。所以验证时必须分段确认，而不是只看最后一步。

#### ③ 部署过程中的常见问题

| 现象 | 根因 | 解法 |
|---|---|---|
| node-exporter 起不来，端口冲突 | 集群已安装 ARMS，占用 9100 | 改监听 19100 |
| PVC 一直 Pending，事件报 ProvisioningFailed | ESSD 最小容量是 20GiB | 把 10GiB 改成 20GiB |
| Grafana 启动后被杀，反复重启 | Grafana 13 冷启动超过 2 分钟，默认 liveness 太激进 | `initialDelaySeconds` 提到 240 以上 |
| Grafana 重启后数据丢失、反复重跑迁移 | 没有显式指定 `GF_PATHS_DATA`，`grafana.db` 落在容器可写层 | 显式指定数据目录并挂 PVC |
| wecom-adapter 无法访问企业微信 | 节点无 NAT，Terway Pod 借不到节点 EIP | `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` + `nodeSelector` 选带 EIP 的节点 |
| 改了 ConfigMap 但配置不生效 | `subPath` 挂载的 ConfigMap 不会热更新 | 改完执行 `kubectl rollout restart` |
| Prometheus 启动即退出，日志报字段不存在 | 配置里写成了 `alertmanager_configs`，正确字段是 `alertmanagers` | 改字段名后重启 |

其中需要特别注意：Prometheus 配置在启动时一次性解析，字段名错误不会被忽略，而是直接拒绝启动，表现为 `CrashLoopBackOff`。Prometheus 无法启动时，应首先检查其输出的 `Error loading config` 日志。

#### ④ 告警规则设计

一条典型的副本不足告警：

```yaml
- alert: DemoDeploymentReplicasMismatch
  expr: kube_deployment_status_replicas_available{namespace="demo"} < kube_deployment_spec_replicas{namespace="demo"}
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "demo 命名空间副本不足: {{ $labels.deployment }}"
```

两个设计要点：

- **`for: 2m`**：指标短暂波动不算故障，连续 2 分钟不满足才升级为 firing。没有它，一次正常的滚动更新就会刷屏。
- **表达式比较的是期望值与实际值**：将副本数主动缩容至 0 时 `0 < 0` 不成立，不触发告警。该行为符合设计预期——主动停止的服务不应告警，仅“期望运行但未能运行”的情况需要告警。

#### ⑤ 告警链路验证要点

| 检查点 | 命令 / 位置 | 通过标准 |
|---|---|---|
| Prometheus 是否算出告警 | `/api/v1/alerts` | `state` 为 `firing` |
| 适配器是否推送成功 | `kubectl logs deploy/wecom-adapter` | 日志出现 `wecom accepted=True` |
| 人是否真的收到 | 企业微信群 | 群里有对应消息 |

三者缺一，就说明断在不同环节：只有第一个说明 Alertmanager 或网络有问题；前两个都有但没收到，通常是在看旧消息或机器人被移出群。

#### ⑥ 给三个管理入口加访问控制

监控组件默认没有任何认证，谁能访问到域名谁就能看到整个集群的指标和告警历史。用 ingress-nginx 的注解加一层 HTTP Basic：

```bash
# 生成密码文件（-c 只在第一次用）
htpasswd -c /tmp/monitoring-auth admin

# 存成 Secret，键名必须是 auth
kubectl -n monitoring create secret generic monitoring-basic-auth \
  --from-file=auth=/tmp/monitoring-auth

# 给 Ingress 加三个注解
kubectl -n monitoring annotate ingress monitoring-ingress \
  nginx.ingress.kubernetes.io/auth-type=basic \
  nginx.ingress.kubernetes.io/auth-secret=monitoring-basic-auth \
  nginx.ingress.kubernetes.io/auth-realm="Authentication Required"
```

Secret 里的键名必须叫 `auth`，因为 ingress-nginx 默认就是去找这个键。改 Ingress 注解不需要重启控制器，它一直在监听对象变化。

---

### 5.8 阶段八：故障演练（6 个案例）

**目标**：不是"知道有这些错误类型"，而是"看到症状后能在几分钟内定位到层"。

#### ① Pod 的四类状态

这四类问题的报错来源完全不同，混在一起排查会浪费时间。

| 状态 | 卡在哪一层 | 谁在报错 | 典型原因 |
|---|---|---|---|
| `Pending` | 调度 | kube-scheduler | 资源不够、节点选择器不满足、污点 |
| `ImagePullBackOff` | 拉镜像 | kubelet | tag 不存在、仓库鉴权失败、网络不通 |
| `CrashLoopBackOff` | 容器启动 | 容器进程自己 | 配置错、依赖连不上、启动即退出 |
| `0/1 Running` | 就绪判定 | kubelet 探针 | readiness 不通过，但进程还活着 |

一个最容易被忽略的事实：**Pod 是 Running，不等于服务可用**。中间隔着一个 readiness 判定。

#### ② 六个案例一览

| # | 注入手法 | 看到的症状 | 定位信号 | 修复 |
|---|---|---|---|---|
| 1 | 指定不存在的镜像 tag | `ImagePullBackOff` | `failed to pull image` | 改成存在的 tag；同时确认 Deployment 带了 `imagePullSecrets` |
| 2 | 把 readinessProbe 路径改成不存在的页面 | 新 Pod `0/1 Running`，滚动更新停住 | `Readiness probe failed: statuscode: 404` | 路径改回真实页面 |
| 3 | 把 requests 设成 8C16G | `Pending`，NODE 列为 `<none>` | `Insufficient cpu / memory` | 调回合理值 |
| 4 | drain 掉一台节点 | 业务 Pod 迁移，绑定节点的 Pod 变 Pending | 节点 `SchedulingDisabled`；`nodeSelector` 无法满足 | `uncordon` 恢复 |
| 5 | 改坏 Service 的 selector | 访问 503，Pod 却是 Running | `ENDPOINTS` 变成 `<none>` | selector 改回真实标签 |
| 6 | 改坏 Ingress 后端端口 | 同域名下 `/` 503，`/api` 正常 | 只有单条 path 失效 | 端口改回 |

#### ③ 通用排查顺序

遇到 `503`，按这个顺序查，基本三步内能定位：

1. **Service 的 endpoints 有没有地址** —— `kubectl get endpoints <svc>`。空的话，问题在 selector 或 Pod 没 Ready。
2. **有地址，就看 Ingress 的后端端口和 Service 的端口是否一致** —— 不一致就是配置错误。
3. **都一致，再看 Pod 是否 Ready** —— `kubectl get pods` 的 READY 列。

反过来，遇到 `404` 就不是后端问题，而是路由规则没匹配上，先看 Ingress 的 host 和 path。

#### ④ 两个附带发现

**裸 Pod 是反模式**。集群里有两个早期验证用的裸 Pod（没有 Deployment/ReplicaSet 管理）。drain 节点时直接报错：

```text
cannot delete Pods that declare no controller (use --force to override)
```

这不是 bug，是保护机制：drain 默认只删"删了能自动重建"的 Pod。裸 Pod 删了就真没了，所以必须显式加 `--force` 表示"我知道它不会回来"。

**DaemonSet 在节点被 drain 时保住了入口**。drain 掉绑着 EIP 的节点后，从集群内测 `lab.local` 仍然返回 200。原因是 ingress-nginx 以 DaemonSet 部署，那台节点上的控制器 Pod 属于"每节点一份"，不会被驱逐；配合 `externalTrafficPolicy: Local`，这台节点仍然接得住流量。如果当初用的是普通 Deployment 且副本都在另一台节点，这次演练就会直接让入口 502。

---

### 5.9 阶段九：巡检脚本与 Ansible 幂等

**目标**：把"每次出事再去查"变成"每天主动扫一遍"，并让环境初始化可以重复执行。

#### ① 巡检范围

巡检不是把所有命令堆在一起，而是先想清楚"哪些问题会悄悄发生"。

| 检查项 | 目的 | 方法 |
|---|---|---|
| 节点是否 Ready | 节点掉了但业务 Pod 可能还在别处跑 | `kubectl get nodes`，第 2 列不是 Ready 就报警 |
| 非 Running 的 Pod | Pending / CrashLoop 可能长期存在没人管 | `kubectl get pods -A --field-selector=status.phase!=Running` |
| 容器重启次数 ≥5 | 悄悄重启、偶发抖动，看 Pod 状态是看不到的 | 遍历 `.status.containerStatuses[*].restartCount` |
| Deployment 副本偏差 | 期望 2 个实际 1 个，业务已经在降级 | 比较 `.spec.replicas` 与 `.status.readyReplicas` |
| 入口连通性 | 集群内一切正常，但外部访问不了 | 在控制器 Pod 内 curl 一次 |
| 节点资源水位 | 内存打满前没有缓冲 | `kubectl top nodes` |

#### ② 脚本中的三个关键写法

```bash
set -uo pipefail
```

- `-u`：用了未定义变量就报错，防止变量名拼错却静默为空。
- `-o pipefail`：管道里任意一段失败即整体失败。默认只取最后一段的退出码，前面错了会被掩盖。

```bash
exec > >(tee "$LOG") 2>&1
```

把后续所有输出同时写到屏幕和日志文件。`tee` 是分叉：一份给屏幕，一份落盘。这样"看到了"和"留档了"一次完成。

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.name}{"="}{.restartCount}{" "}{end}{"\n"}{end}' \
  | awk '{for(i=2;i<=NF;i++){split($i,a,"="); if(a[2]>=5) print $1, a[1], a[2]}}'
```

`jsonpath` 直接从 API 返回的 JSON 里按路径取字段，比用 `grep` 解析文本稳。`awk` 再逐个容器判断重启次数。`NF` 是当前行的字段总数。

#### ③ Ansible 的作用：幂等而非批量

很多人以为 Ansible 是用来一次管很多台机器的。它真正的价值是**声明式**：

| 方式 | 声明内容 | 二次执行结果 |
|---|---|---|
| Shell 脚本 | **怎么做**：`apt install`、`chmod 600`、`systemctl start` | 每条都再执行一次 |
| Ansible | **应该是什么状态**：包存在、权限是 600、服务在运行 | 已满足就 `ok` 跳过 |

该思路与 `kubectl apply` 一致：声明期望状态，由工具完成比对与收敛。

#### ④ 幂等的三种输出

| 标记 | 含义 |
|---|---|
| `ok` | 检查过了，本来就是想要的样子，没动 |
| `changed` | 检查发现不一致，改了 |
| `skipping` | `when` 条件不成立，整段跳过 |

验证幂等不能只看第一遍。正确的做法是三步：

1. 环境本来就正确 → 跑一遍，应当 `changed=0`
2. 故意制造偏差（例如 `chmod 644 /root/.kube/config`）→ 再跑，应当 `changed=1`
3. 再跑一次 → 回到 `changed=0`

只做第 1 步，只能证明"不会乱改"；第 2、3 步才证明"该改的时候会改"。

#### ⑤ 实现 `changed=0` 的三处配置

```yaml
- name: 基础包存在
  ansible.builtin.apt:
    name: "{{ base_packages }}"
    state: present
    update_cache: true
    cache_valid_time: 3600
```

`cache_valid_time` 让一小时内不重复 `apt update`。没有它，每次执行都会触发一次更新，永远做不到零变更。

```yaml
- name: 读取当前时区
  ansible.builtin.command: timedatectl show -p Timezone --value
  register: tz_now
  changed_when: false

- name: 时区设为 Asia/Shanghai
  ansible.builtin.command: timedatectl set-timezone Asia/Shanghai
  when: tz_now.stdout != "Asia/Shanghai"
```

`command` 模块默认认为"执行了就是 changed"，所以查询类命令必须显式写 `changed_when: false`。修改类命令用 `when` 先判断，条件不成立就跳过。

```yaml
- name: kubeconfig 权限 0600
  ansible.builtin.file:
    path: /root/.kube/config
    state: file
    mode: '0600'
```

`mode` 一定要加引号。YAML 里不加引号的 `0600` 容易被当成数字处理。

#### ⑥ 不使用 `shell` 模块的原因

```yaml
- name: 装 unzip
  ansible.builtin.shell: apt-get install -y unzip
```

这样写永远报 `changed`。Ansible 只能看到"我执行了一条命令、退出码 0"，无法判断系统到底变没变。能用语义化模块（`apt`、`file`、`systemd`）时，就不要退化成 `shell`。

---

### 5.10 阶段十：备份恢复与重建验收

**目标**：证明"这套东西能被完整重建"，而不只是"现在能跑"。

#### ① 备份范围

| 对象 | 命令 | 说明 |
|---|---|---|
| 业务数据 | `mysqldump` | 数据库里的数据是唯一不可再生的 |
| 对象清单 | `kubectl get ... -o yaml` | 重建时不用凭记忆重写一遍 |

```bash
kubectl -n demo exec mysql-0 -- sh -c \
  'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --databases demo --single-transaction --routines' \
  > /root/backup/mysql-demo-$(date +%F-%H%M).sql
```

- `--databases demo`：导出时带上 `CREATE DATABASE` 和 `USE`，恢复时不用先建库。
- `--single-transaction`：对 InnoDB 用一致性快照读，**不锁表**。线上库备份必须加。
- `--routines`：连存储过程和函数一起导出。
- `>` 在**本地**执行，mysqldump 的输出通过 kubectl 的标准输出传回来再落盘。

清单导出刻意**不含 Secret**：

```bash
kubectl -n demo get deploy,statefulset,svc,cm,pvc -o yaml > /root/backup/demo-manifests-$(date +%F-%H%M).yaml
```

清单会进归档、可能被复制来复制去，凭据不该混在里面。

#### ② 恢复演练

```bash
# 1. 删表
kubectl -n demo exec mysql-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" demo -e "DROP TABLE orders;"'

# 2. 确认真的没了（无输出即空）
kubectl -n demo exec mysql-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "show tables;" demo'

# 3. 从备份恢复（注意不要指定库名）
kubectl -n demo exec -i mysql-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' < /root/backup/mysql-demo-*.sql

# 4. 验证数据回来
kubectl -n demo exec mysql-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "select * from orders;" demo'
```

第 3 步**不要**在末尾写库名：备份文件里自带 `CREATE DATABASE` 和 `USE`，由文件自己决定写进哪个库。

只导出不恢复的备份，等于没有备份。必须真的删一次、恢复一次，才算验证过。

#### ③ 全量重建：在新命名空间中部署

重建一套完整应用，依赖三件东西，缺一不可：

| 依赖 | 作用 | 缺了会怎样 |
|---|---|---|
| `acr-pull`（dockerconfigjson） | 拉私有镜像的凭据 | `ImagePullBackOff` / 401 |
| `mysql-secret`（root-password / app-password） | 数据库口令 | MySQL 起不来，API 连不上 |
| `mysql-initdb`（01-init.sql） | 初始化脚本 | 库是空的，表不存在 |

```bash
# 建命名空间
kubectl create namespace demo2

# 复制拉取凭据（键名里的点要转义）
kubectl -n demo get secret acr-pull -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d > /tmp/acr.json
kubectl -n demo2 create secret generic acr-pull \
  --from-file=.dockerconfigjson=/tmp/acr.json \
  --type=kubernetes.io/dockerconfigjson

# 应用清单（目录形式）
kubectl apply -f /root/demo2/

# 等数据库就绪（要申请新云盘 + 初始化，比普通 Deployment 慢）
kubectl -n demo2 rollout status statefulset/mysql --timeout=240s

# 验证整条链路
kubectl -n demo2 exec deploy/ack-api -- wget -qO- http://127.0.0.1:8080/db-check
```

`-f` 给目录时，kubectl 会按文件名排序依次 apply。顺序不影响结果：Pod 起不来会自己重试，直到依赖就绪。

#### ④ 容器内 localhost 可能解析到 IPv6

在容器里执行 `wget http://localhost:8080/db-check` 报 `Connection refused`，但服务明明是好的。原因在 `/etc/hosts`：

```text
127.0.0.1   localhost
::1         localhost
```

`localhost` 会同时解析到 IPv4 和 IPv6。wget 优先尝试 `::1`，而服务通常只监听 `0.0.0.0`（IPv4），于是被拒。换成 `127.0.0.1` 立刻正常。

**容器内排查服务，直接用 `127.0.0.1` 更稳。**

#### ⑤ 资源拆除与验证

```bash
kubectl delete namespace demo2
```

删除命名空间会级联删除下面所有对象，包括 PVC；PVC 删除后云盘按回收策略释放，账单不再计费。这是"能搭也能拆"的完整性证明。

---

## 6. 常见故障与处理方法

本章记录实验过程中出现的 6 类故障，按“现象 → 原因 → 处理”组织。

**问题 1：Pod 处于 ImagePullBackOff 状态**

- **现象**：Pod 无法启动，Events 显示 `failed to pull image` 或 `no such host`。
- **原因**：镜像地址使用 ACR 公网域名。节点位于 VPC 内且未配置 NAT 网关，无法解析或访问公网域名。
- **处理**：集群内部署的镜像地址改为 VPC 域名（`crpi-xxxx-<region>.personal.cr.aliyuncs.com`，注意 `-vpc` 后缀）。
- **规则**：本机转存使用公网域名，集群内拉取使用 VPC 域名。

**问题 2：StatefulSet 未自动重建 Pod**

- **现象**：`mysql-0` 因探针失败或节点异常处于未就绪状态，长时间不恢复。
- **原因**：StatefulSet 为保证有状态服务的数据一致性，对未就绪的 Pod 采取等待策略，不会像 Deployment 那样直接替换。
- **处理**：确认数据盘未被占用后，手动删除 Pod 触发重建：`kubectl -n demo delete pod mysql-0`。PVC 会原位挂回，数据不受影响。

**问题 3：Ingress 的 ADDRESS 显示为 Pod IP**

- **现象**：`kubectl get ingress` 输出的地址不是公网 EIP。
- **原因**：控制器默认将自身地址上报为入口地址。
- **处理**：为控制器增加 `--publish-status-address=<EIP>` 参数。该改动会触发控制器滚动重启，可能同时触发问题 4。

**问题 4：公网访问返回 000，集群内访问正常**

- **现象**：浏览器无法打开页面，`curl` 返回 `000`；集群内访问 NodePort 与 Service 均正常。
- **原因**：`externalTrafficPolicy: Local` 仅将流量转发至本节点上的 Pod。EIP 绑定的 j 区节点上没有控制器 Pod（全部调度至 k 区），流量无本地后端可转。
- **处理**：将控制器由 Deployment 改为 DaemonSet，确保每个节点均存在本地 Pod。修改后节点调度变化不再影响入口。
- **说明**：该问题属于架构层面的策略与部署方式不匹配，并非参数配置错误。出现“集群内可访问、集群外不可访问”，且入口使用固定节点与 Local 策略时，应先确认入口节点上是否存在本地控制器 Pod。

**问题 5：镜像推送成功但拉取端提示清单格式不支持**

- **现象**：`docker push` 无报错，另一侧拉取时提示 manifest 格式不受支持。
- **原因**：新版 buildx 默认为镜像附加 provenance / SBOM 元数据，生成 OCI index 多架构清单，部分仓库实现（自建 Harbor 或旧版本私有仓库）支持不完整。
- **处理**：构建时增加 `--provenance=false --sbom=false`。

**问题 6：Jenkins 凭据校验失败**

- **现象**：配置 SSH 私钥凭据后，拉取代码报认证失败。
- **原因**：粘贴私钥文本时首行含空行或空格，导致私钥解析失败。
- **处理**：确认首行为 `-----BEGIN OPENSSH PRIVATE KEY-----`，前后无空白字符。

**其他注意事项**

- 通过 REST API 调用 Jenkins 写接口时，需携带 cookie jar 与 Jenkins-Crumb，否则返回 403。
- 部分版本的 kubectl auth can-i 对 pods/exec 的判断与实际行为不一致，应以实际执行结果为准。

---

## 7. 成本控制实践

### 7.1 成本控制手段

| 手段 | 效果 |
|---|---|
| 用基础版集群 | 管理费从约 460 元/月降到 ¥0 |
| 全抢占式实例 | 节点成本降到按量的 1/5，两台每天省约 30 元 |
| 不建 NAT 网关 | 省约 4.7 元/天 |
| 应用入口不买 SLB | 省去一整个账单项 |
| EIP 选按使用流量 | 低流量场景比按固定带宽便宜 |
| 实验间隙停机构建节点 | 停机后不计实例费 |
| 镜像仓库用 ACR 个人版 | ¥0 |
| 存储按需（20 GiB） | 云盘按量计费，随 PVC 释放而停止 |

### 7.2 实测成本构成（2026-10-18 账单）

![ACK-06-成本构成.png](images/ACK-06-成本构成.png)

*每天在花什么钱：按现有在线资源拆分。*

| 项目 | 口径 | 元/天 |
|---|---|---|
| worker-k8s-j（4C8G 抢占式） | 按量 | 4.31 |
| worker-k8s-for-k（4C8G 抢占式） | 按量 | 4.31 |
| 两台节点系统盘（40GiB ESSD） | 0.00105 元/GiB·h | 2.02 |
| 两块数据盘（20GiB ESSD，MySQL + Prometheus） | 同上 | 2.02 |
| **ACK 托管内网 SLB** | 按小时 | **3.00** |
| Jenkins 系统盘（停机照收） | 同上 | 1.01 |
| EIP 保有费 | 0.02 元/时 | 0.48 |
| 日志服务（audit + ingress） | 按量 | ≈0.6 |
| **合计（Jenkins 停机）** | | **≈17.6** |
| Jenkins 开机时额外 | 0.32 元/时 | **≈24** |

上述构成中有三点需要说明：

1. **内网托管 SLB 是最易遗漏的计费项。** 集群未单独购买负载均衡，但 ACK 为 API Server 创建的内网托管 SLB 自建集群起持续计费，约 3 元/天，占比接近五分之一。
2. **停机不等于停止计费。** ECS 停止后计算资源费用停止，系统盘仍按容量计费，约 1 元/天。
3. **云盘按容量线性计费。** 20 GiB 的 PVC 约 0.5 元/天，两块合计约 1 元。实验环境中新增 PVC 同样产生费用。

按 17.6 元/天计算，300 元预算可支撑约 17 天在线；按 24 元/天（Jenkins 开机）约 12 天。

### 7.3 资源释放清单

实验结束后，按以下顺序释放，避免产生「遗忘的资源」持续计费：

| 顺序 | 资源 | 释放方式 | 注意 |
|---|---|---|---|
| 1 | PVC | `kubectl delete pvc` | StorageClass 为 Delete 策略时，同时释放云盘 |
| 2 | ACK 集群 | 控制台删除集群 | 勾选同时删除关联资源（节点、云盘、**内网托管 SLB** 一起释放） |
| 3 | EIP | 控制台解绑并释放 | 只解绑不释放仍会继续计费 |
| 4 | ECS（Jenkins） | 释放实例 | 确认不再需要时释放，停机只是省实例费 |
| 5 | ACR 仓库与镜像 | 控制台删除 | 个人版免费，可视需要保留 |
| 6 | 快照 / 镜像 / 云盘残留 | 控制台核对 | **账单核对**这一步不能省 |

> **重要**：删除 PVC 会同时删除云盘。生产环境中数据库的 PVC 通常配置 `Retain` 策略以防误删；实验环境用 `Delete` 是为了保证不残留计费资源。**两种策略的差异必须心里有数。**

---

## 8. 结论与后续工作

### 8.1 设计要点

本实验涉及的判断逻辑可归纳为以下五条：

1. **入口地址是链路的锚点。** 排查自公网 IP 开始，逐跳向内（EIP → 节点端口 → 控制器 → Service → Pod），可快速定位断点。
2. **权限按最小可用原则授予。** Jenkins 仅需修改镜像版本，因此只授予 Deployment 的修改权限。
3. **有状态与无状态服务区别对待。** Deployment 与 StatefulSet 的选择依据是服务能否被随意替换，而非技术偏好。
4. **成本在设计阶段确定。** 集群版本、实例计费方式与入口方案的选择，在实施前即决定了成本量级。
5. **单次变更只引入一个变量。** 分阶段推进与逐阶段验证，可将故障排查范围限制在单个阶段内。

### 8.2 后续可扩展方向

十个阶段完成后，环境已具备交付、监控、排障与重建能力。可继续扩展的方向如下：

| 方向 | 具体做法 |
|---|---|
| HTTPS | cert-manager + 免费证书，把 443/30443 用起来 |
| 入口高可用 | 两个节点各绑一个 EIP 做 DNS 轮询，或改用 ALB |
| 日志体系 | EFK 或 Loki，把各容器日志集中检索 |
| 指标长期存储 | Prometheus remote write 到 TSDB，突破本地保留期 |
| GitOps | Argo CD 接管部署，让仓库成为唯一期望状态来源 |
| 混沌工程 | Chaos Mesh 做节点、Pod、网络层的故障注入 |

### 8.3 复现路线

复现时按下表顺序执行，各阶段对应前文相应小节：

| 阶段 | 关键动作 | 预计耗时 |
|---|---|---|
| 一 | 控制台创建 ACK 基础版集群，确认节点 Ready、系统组件正常 | 10 min |
| 二 | 加第二个可用区的节点池 | 5 min |
| 三 | 建 ACR 仓库、转存镜像、配 RAM 拉取授权、验证拉取门 | 30 min |
| 四 | 部署 mysql / api / web 三份清单，验证 `/db-check` | 20 min |
| 五 | EIP 绑节点、安全组放行 30080、部署 ingress-nginx（DaemonSet） | 30 min |
| 六 | 装 Jenkins、配凭据与流水线、跑通发布与回滚 | 60 min |
| 七 | 五个监控组件 + 告警规则 + 企业微信通知 | 90 min |
| 八 | 六个故障案例逐个注入并恢复 | 60 min |
| 九 | 巡检脚本 + Ansible 幂等验证 | 40 min |
| 十 | 备份恢复 + 换命名空间重建 + 拆除 | 30 min |

复现过程中最易受阻的三处为：阶段三的 RAM 按仓库 ARN 授权、阶段五的 EIP 与 DaemonSet 配合、阶段六的 Jenkins 仅监听 127.0.0.1 导致 Webhook 不可用。实施前可先阅读相应小节的故障记录。

---

## 9. 参考资料

- 阿里云 ACK 官方文档：集群创建、节点池管理、Ingress 组件说明
- 阿里云容器镜像服务（ACR）个人版文档：命名空间、仓库、访问凭证与 RAM 授权
- 阿里云弹性公网 IP 文档：计费方式（按固定带宽 / 按使用流量）与保有费说明
- ingress-nginx 官方部署文档：Bare-metal 部署清单与控制器参数说明
- Kubernetes 官方文档：Deployment / StatefulSet / Service / Ingress / RBAC 概念
- Jenkins 官方文档：Pipeline from SCM、凭据管理与 Webhook 触发

---

> **说明**：本文为学习实验记录，集群 ID、实例 ID、RAM 用户名等标识已作脱敏处理；文中 IP 与端口为实验环境实际取值，执行前需替换为实际地址。命令与清单按实验环境整理，不同 Kubernetes 版本与地域下参数可能存在差异，以官方文档为准。