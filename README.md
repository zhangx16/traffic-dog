# dog-alpine

Alpine Linux 端口流量统计脚本。  
核心功能：用 `nftables` 按端口统计 TCP/UDP 入站、出站和总流量。

本项目只保留端口流量统计功能，适合在 Alpine VPS、转发机、轻量容器宿主机上使用。

## 功能

- 支持 Alpine Linux / BusyBox `/bin/sh`
- 使用 `nftables` 计数器统计流量
- 支持 TCP / UDP
- 支持单端口和端口段，例如 `80`、`443`、`10000-10100`
- 支持 `input` / `output` / `forward` 链统计
- 支持 OpenRC 开机自动恢复规则
- 不依赖 `bash`、`jq`、`bc`

## 一键安装

在 Alpine 服务器上使用 `root` 执行：

```sh
wget -qO- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh
```

如果系统没有 `wget`，也可以使用：

```sh
apk add --no-cache curl
curl -fsSL https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh
```

一键安装并直接添加统计端口：

```sh
wget -qO- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh -s -- 80 443
```

添加端口段：

```sh
wget -qO- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh -s -- 80 443 10000-10100
```

不安装开机服务：

```sh
wget -qO- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh -s -- --no-service 80 443
```

## 手动安装

```sh
apk add --no-cache nftables

wget -O /usr/local/bin/port-traffic-stat \
  https://raw.githubusercontent.com/zhangx16/dog-alpine/main/port-traffic-stat.sh

chmod +x /usr/local/bin/port-traffic-stat

port-traffic-stat install-service
port-traffic-stat restore
```

## 使用方法

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

卸载脚本和启动服务，保留统计数据目录：

```sh
port-traffic-stat uninstall
```

## 输出说明

示例：

```text
PORT                         IN            OUT          TOTAL  RESET_AT
----------------  --------------  -------------  -------------  ------------------------
80                      12.30MB        98.40MB       110.70MB  2026-07-06T20:00:00+0800
443                      1.20GB         4.80GB         6.00GB  2026-07-06T20:00:00+0800
TOTAL                    1.21GB         4.90GB         6.11GB
```

字段含义：

- `IN`：目标端口 `dport` 命中流量，包含 `input` / `forward`
- `OUT`：源端口 `sport` 命中流量，包含 `output` / `forward`
- `TOTAL`：`IN + OUT`
- `RESET_AT`：该端口最近一次清零时间

## 文件位置

安装后：

```text
/usr/local/bin/port-traffic-stat
/etc/port-traffic-stat/ports
/etc/port-traffic-stat/state
/etc/init.d/port-traffic-stat
```

## 常见问题

### chmod: port-traffic-stat.sh: No such file or directory

说明当前目录没有脚本文件。推荐直接使用一键安装：

```sh
wget -qO- https://raw.githubusercontent.com/zhangx16/dog-alpine/main/install.sh | sh
```

### rules not loaded

执行：

```sh
port-traffic-stat restore
```

### 重启后统计规则消失

安装 OpenRC 服务：

```sh
port-traffic-stat install-service
rc-service port-traffic-stat start
```

## 参考

- [zywe03/realm-xwPF](https://github.com/zywe03/realm-xwPF)
- [port-traffic-dog.sh](https://github.com/zywe03/realm-xwPF/blob/main/port-traffic-dog.sh)
