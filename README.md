# Traffic-dog

Alpine / Debian 通用的端口流量统计与限额暂停脚本。

核心功能：使用 `nftables` 按端口统计 TCP/UDP 入站、出站、总流量；可为端口设置总流量限额，当该端口 `IN + OUT` 达到限额后，自动暂停该端口流量。

## 支持系统

- Alpine Linux，OpenRC
- Debian / Ubuntu，systemd
- Debian 系 SysV init 环境，使用 `update-rc.d`

依赖：`nftables`。一键脚本会自动安装 `nftables`、`ca-certificates`、`curl`。

## 功能

- 使用 `/bin/sh`，兼容 BusyBox ash 和 Debian dash
- 使用 `nftables` 计数器统计流量
- 使用 `nftables quota` 实现内核级自动暂停，无需常驻轮询进程
- 支持 TCP / UDP
- 支持单端口和端口段，例如 `80`、`443`、`10000-10100`
- 支持 `input` / `output` / `forward` 链统计
- 支持 OpenRC、systemd、SysV init 开机自动恢复规则
- 支持交互式数字菜单
- 不依赖 `bash`、`jq`、`bc`

## 一键安装

使用 `root` 执行：

```sh
wget -O- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh
```

如果系统没有 `wget`，可以使用：

Alpine：

```sh
apk add --no-cache curl
curl -fL https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh
```

Debian / Ubuntu：

```sh
apt-get update
apt-get install -y ca-certificates curl
curl -fL https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh
```

一键安装并添加统计端口：

```sh
wget -O- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh -s -- 80 443
```

一键安装、添加端口，并给每个端口设置 10G 总流量限额：

```sh
wget -O- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh -s -- --limit 10G 80 443
```

端口段示例：

```sh
wget -O- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh -s -- --limit 500M 10000-10100
```

不安装开机服务：

```sh
wget -O- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh -s -- --no-service 80 443
```

## 手动安装

Alpine：

```sh
apk add --no-cache nftables ca-certificates curl
```

Debian / Ubuntu：

```sh
apt-get update
apt-get install -y --no-install-recommends nftables ca-certificates curl
```

下载脚本：

```sh
wget -O /usr/local/bin/port-traffic-stat \
  https://raw.githubusercontent.com/zhangx16/dog-alpine/main/port-traffic-stat.sh

chmod +x /usr/local/bin/port-traffic-stat
```

安装开机服务并恢复规则：

```sh
port-traffic-stat install-service
port-traffic-stat restore
```

Debian / Ubuntu systemd 可选启动命令：

```sh
systemctl daemon-reload
systemctl enable --now port-traffic-stat
```

## 交互式菜单

直接运行：

```sh
port-traffic-stat
```

或：

```sh
port-traffic-stat menu
```

会进入数字菜单，可通过输入数字执行常用功能：

```text
1) Add/Set ports              添加统计端口
2) Set port traffic limit     设置端口限额
3) Show status                查看状态
4) Show limits                查看限额
5) Delete ports               删除端口
6) Remove port limit          删除限额
7) Resume paused port         恢复端口流量
8) Reset statistics           清零统计
9) Restore nftables rules     恢复规则
10) Install dependencies      安装依赖
11) Install script            安装脚本
12) Install boot service      安装开机服务
13) Update script             更新脚本
14) Uninstall script/service  卸载脚本/服务
15) Watch status              实时查看状态
0) Exit                       退出
```

原有命令行方式仍然保留，适合脚本化调用。

## 命令行使用

添加统计端口：

```sh
port-traffic-stat add 80 443
```

添加端口段：

```sh
port-traffic-stat add 10000-10100
```

查看统计：

```sh
port-traffic-stat status
```

实时刷新查看：

```sh
port-traffic-stat watch 2
```

删除端口：

```sh
port-traffic-stat del 80
```

清零全部统计：

```sh
port-traffic-stat reset all
```

清零指定端口：

```sh
port-traffic-stat reset 443
```

## 流量限额与自动暂停

给端口设置总流量限额：

```sh
port-traffic-stat limit 80 10G
```

含义：端口 `80` 的 `IN + OUT` 达到 `10G` 后，`nftables` 会自动 drop 该端口后续 TCP/UDP 流量。

也可以使用完整写法：

```sh
port-traffic-stat limit set 80 10G
```

查看限额：

```sh
port-traffic-stat limit list
```

移除限额并恢复不限流：

```sh
port-traffic-stat limit del 80
```

或：

```sh
port-traffic-stat unlimit 80
```

端口达到限额后，如果想重新放行并从 0 开始计算：

```sh
port-traffic-stat resume 80
```

恢复全部端口并重新计数：

```sh
port-traffic-stat resume all
```

支持的限额格式：

```text
500M
10G
1T
1073741824
```

## 其他命令

保存当前计数：

```sh
port-traffic-stat save
```

恢复 nftables 统计规则：

```sh
port-traffic-stat restore
```

卸载 nftables 规则，但保留历史统计：

```sh
port-traffic-stat flush
```

更新脚本：

```sh
port-traffic-stat update
```

卸载脚本和启动服务，保留统计数据目录：

```sh
port-traffic-stat uninstall
```

## 输出说明

示例：

```text
PORT                         IN            OUT          TOTAL          LIMIT  STATE    RESET_AT
----------------  --------------  -------------  -------------  -------------  -------- ------------------------
80                      12.30MB        98.40MB       110.70MB        10.00GB  LIMITED  2026-07-06T20:00:00+0800
443                      1.20GB         4.80GB         6.00GB        10.00GB  LIMITED  2026-07-06T20:00:00+0800
10000-10100             500.00MB          0.00B       500.00MB       500.00MB PAUSED   2026-07-06T20:00:00+0800
TOTAL                    1.70GB         4.90GB         6.60GB
```

字段含义：

- `IN`：目标端口 `dport` 命中流量，包含 `input` / `forward`
- `OUT`：源端口 `sport` 命中流量，包含 `output` / `forward`
- `TOTAL`：`IN + OUT`
- `LIMIT`：端口总流量限额，`-` 表示未设置
- `STATE`：
  - `OPEN`：未设置限额
  - `LIMITED`：已设置限额，尚未达到
  - `PAUSED`：已达到限额，端口流量已暂停
- `RESET_AT`：该端口最近一次清零时间

## 文件位置

安装后：

```text
/usr/local/bin/port-traffic-stat
/etc/port-traffic-stat/ports
/etc/port-traffic-stat/state
/etc/port-traffic-stat/limits
/etc/port-traffic-stat/used
/etc/init.d/port-traffic-stat                    # Alpine OpenRC 或 Debian SysV
/etc/systemd/system/port-traffic-stat.service    # Debian/Ubuntu systemd
```

## Debian 注意事项

Debian 默认也可以使用 `nftables`。如果系统同时运行其他防火墙管理器，例如 `ufw`、`firewalld` 或自定义 `/etc/nftables.conf`，本脚本会创建独立表：

```text
inet port_traffic_stat
```

不会修改系统已有防火墙表。若其他服务在运行中执行 `nft flush ruleset`，需要重新执行：

```sh
port-traffic-stat restore
```

或启用开机服务：

```sh
port-traffic-stat install-service
systemctl enable --now port-traffic-stat
```

## 常见问题

### 安装命令执行后没有任何反馈

不要使用静默参数 `wget -qO-`，下载失败时它可能不显示任何错误。请使用：

```sh
wget -O- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh
```

或：

```sh
curl -fL https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh
```

安装后检查：

```sh
command -v port-traffic-stat
ls -l /usr/local/bin/port-traffic-stat
port-traffic-stat version
```

### chmod: port-traffic-stat.sh: No such file or directory

说明当前目录没有脚本文件。推荐直接使用一键安装：

```sh
wget -O- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh
```

### rules not loaded

执行：

```sh
port-traffic-stat restore
```

### 重启后统计规则消失

Alpine / OpenRC：

```sh
port-traffic-stat install-service
rc-service port-traffic-stat start
```

Debian / systemd：

```sh
port-traffic-stat install-service
systemctl start port-traffic-stat
```

### 达到限额后如何恢复端口流量

保留限额、重新从 0 开始：

```sh
port-traffic-stat resume 80
```

取消限额、不再暂停：

```sh
port-traffic-stat unlimit 80
```

## 参考

- [zywe03/realm-xwPF](https://github.com/zywe03/realm-xwPF)
- [port-traffic-dog.sh](https://github.com/zywe03/realm-xwPF/blob/main/port-traffic-dog.sh)
- [nftables nft 手册：quota 语法](https://www.mankier.com/8/nft)
