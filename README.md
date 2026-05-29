# IPGuard (单机版)

一个轻量级的单机 agent，通过向目标地区注入高拟真的本地用户流量，来维护 VPS
出口 IP 的地理定位信号与信誉。

这是一个 **单机版 fork**：原项目的 Master / Telegram 指挥控制、webhook 监听、
OTA 远程推送、装机量遥测已全部移除。agent 完全独立、按计划自行运行，结果只写入
本地日志。

> 仅可用于你自己的合法服务器。它的工作方式是“影响第三方地理定位/风控数据库对
> 某个 IP 的判定”，属于灰色地带，可能与所涉服务的条款冲突。见
> [注意事项](#注意事项)。

## 它做什么

每个周期，agent 会按配置的地区模拟一个真实本地用户（搜索、新闻、地图、访问本地
高信誉站点），从而：

- 让地理定位库（Google / YouTube 等）持续把该 IP 判定在目标地区，而不是漂移、
  或被标成 “CN（送中）”。
- 让欺诈 / 滥用库看到该 IP 有自然、低风险的活动。

它 **不** 修改路由、**不** 走 VPN；只产生出站流量。

## 组成

| 文件 | 作用 |
|------|------|
| `core/runner.sh`     | 调度器。每个周期按加权轮盘选 `mod_google` 或 `mod_trust`。 |
| `core/mod_google.sh` | 地理锚定。用地区坐标 + 关键词 + UA 指纹模拟本地 Google 搜索/新闻/地图；探测该 IP 是否被正确定位。 |
| `core/mod_trust.sh`  | 信誉养护。向本地高信誉/白名单站点注入无害流量。 |
| `core/mod_quality.sh`| 按需 IP 体检（“深海声呐”）。调用外部 [xykt/IPQuality](https://github.com/xykt/IPQuality) 探针；输出欺诈分、代理/VPN 判定、流媒体解锁、25 端口、DNS 黑名单。打印到 stdout + `logs/quality.log`。 |
| `core/updater.sh`    | 每日刷新 UA 池（每 30 天）、关键词、地区规则。 |
| `core/report.sh`     | 每日本地简报，打印到 stdout + `logs/report.log`。 |
| `core/install.sh`    | 裸机安装器（选地区 + 配置调度）。 |
| `core/uninstall.sh`  | 完全卸载。 |
| `data/`              | `map.json`（地区树）、`regions/<C>/<S>/<City>.json`（按城市的规则）、`keywords/kw_<CC>.txt`、`user_agents.txt`。 |
| `entrypoint.sh`        | 容器入口：用环境变量生成配置，然后跑维护循环。 |

## 用 Docker / Podman 运行（推荐）

镜像已由 GitHub Actions 自动发布到 GHCR：`ghcr.io/bex/ipguard`，
多架构支持 `linux/amd64`、`linux/arm64`、`linux/s390x`（拉取时自动匹配）。
下面的命令 Docker 和 Podman 通用 —— 把 `docker` 换成 `podman` 即可，参数一致。

```bash
# 拉取已发布镜像（docker 或 podman 二选一）
docker pull ghcr.io/bex/ipguard:latest
# podman pull ghcr.io/bex/ipguard:latest

# 常驻守护（普通 VPS 上默认就从宿主机公网 IP 出站）：
docker run -d --name ipguard --restart unless-stopped \
  ghcr.io/bex/ipguard:latest

# 一次性命令：
docker run --rm -it ghcr.io/bex/ipguard:latest quality   # IP 体检（报告打印到 stdout）
docker run --rm -it ghcr.io/bex/ipguard:latest once      # 跑一轮维护
docker run --rm -it ghcr.io/bex/ipguard:latest report    # 本地简报
```

本地自行构建（可选，不想用 GHCR 镜像时）：

```bash
docker build -t ipguard .          # 或：podman build -t ipguard .
docker run -d --name ipguard -v ips-logs:/opt/ipguard/logs ipguard
```

用 compose（同一份 `docker-compose.yml` 通用）：

```bash
docker compose up -d --build       # 或：podman compose up -d --build
docker compose logs -f
docker compose run --rm ipguard quality
```

**Podman 备注**

- rootless Podman 的出站同样走宿主机公网 IP，地区自动检测照常工作。
- 开机自启：rootless 下 `--restart unless-stopped` 不一定随系统启动，建议用
  systemd 用户单元（Quadlet `.container` 文件，或 `podman generate systemd`）。
- 日志上限：`docker-compose.yml` 里的 `logging`（json-file）是 Docker 专属；
  Podman 用 `--log-driver` / `--log-opt`（默认 journald），或直接靠容器内的
  `IPS_LOG_STDOUT`（后台默认安静）控制输出量。

### 地区选择

若未设置 `IPS_REGION`，地区会根据出口 IP 的地理位置自动检测（Cloudflare
`cdn-cgi/trace`）。若该国家没有内置规则文件，则回退到 **同大洲** 已支持的国家
（EU->DE、AS->SG、NA->US、OC->AU、AF->NG），最后回退到 US。

用 `IPS_REGION`（国家码）或 `IPS_REGION_FILE`（`data/regions` 下的精确路径）
强制指定。已支持的国家见 `data/regions/`。

### 环境变量

| 变量 | 默认 | 含义 |
|------|------|------|
| `IPS_REGION`        | （自动） | 国家码，如 `US`、`JP`、`DE`。不设 = 自动检测。 |
| `IPS_REGION_FILE`   | -        | 精确规则路径，如 `US/CA/San_Jose.json`（优先于 `IPS_REGION`）。 |
| `IPS_IP_PREF`       | `4`      | 出口锚点优先 IPv4（`4`）还是 IPv6（`6`）。 |
| `IPS_PUBLIC_IP`     | （自动） | 手动钉死出口 IP，不自动探测。 |
| `IPS_ENABLE_GOOGLE` | `true`   | 启用地理锚定模块。 |
| `IPS_ENABLE_TRUST`  | `true`   | 启用信誉养护模块。 |
| `IPS_NODE_ALIAS`    | （自动） | 日志里显示的节点别名。 |
| `IPS_RECONFIG`      | `false`  | `true` 在重启时重新生成配置。 |
| `IPS_LOG_STDOUT`    | `auto`   | 是否把日志转发到 stdout：`auto`（仅在 TTY 下）、`true`、`false`。 |

后台（`-d`）容器默认安静，避免 docker 日志无限增长；完整日志始终保存在挂载的
`logs/` 卷里。compose 文件还对 json 日志做了上限（`max-size: 10m`、
`max-file: 3`）。

## 在裸机上运行

```bash
sudo bash core/install.sh        # 选 大洲 / 国家 / 州；城市自动选第一个
```

安装到 `/opt/ipguard`，生成配置，并配置调度（systemd 定时器，或 cron，或
Alpine 死循环）。之后：

```bash
bash /opt/ipguard/core/runner.sh        # 跑一轮维护
bash /opt/ipguard/core/mod_quality.sh   # IP 体检
bash /opt/ipguard/core/report.sh        # 本地简报
tail -f /opt/ipguard/logs/ipguard.log  # 实时日志
sudo bash /opt/ipguard/core/uninstall.sh
```

## 调度

- `runner.sh`  ：每 20 分钟（带随机错峰抖动）。
- `updater.sh` ：每日一次（UTC）。
- `report.sh`  ：每日 16:00 UTC。
- `mod_quality.sh` ：仅按需运行（不在调度内）。

## 会联系的外部服务

- Cloudflare `cdn-cgi/trace`、`api.ip.sb`、`ipinfo.io` —— 探测出口 IP / 国家。
- Google / YouTube 及本地白名单站点 —— 养护流量本身。
- `xykt/IPQuality` 探针 + 各欺诈库（Scamalytics、AbuseIPDB、IPQS……）—— 仅在 `quality` 时。
- 上游公共数据仓库 —— `updater.sh` 刷新关键词 / UA / 地区规则。

IP 体检探针（`ip_probe.sh`）只在 **首次启动 / 安装时下载一次**，之后复用，不会
定时重下。

## 注意事项

- 它通过模拟流量去“影响第三方地理定位/风控判定”。本意是纠正一台 *合法* 服务器
  被错误标注的位置，但同样的机制也可被滥用。请在所涉服务的条款范围内合理使用。
- `mod_quality.sh` 会以 root 下载并执行第三方脚本（`xykt/IPQuality`）。这是一条
  供应链风险面；介意的话请固定版本 / vendor 进仓库。
- `updater.sh` 从上游公共仓库拉取的是 **数据**（不是代码）。如果你 fork 并改了
  `data/`，每日刷新可能会被上游同名文件覆盖。

## 相对原版移除的东西

没有 Master、Telegram 机器人、webhook C2、HMAC 指令通道、OTA 推送、官方公共
网关、装机量遥测。输出改为本地（stdout + 日志文件），不再发送到 Telegram。
