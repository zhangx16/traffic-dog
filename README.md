# Traffic-dog

基于 nftables 的端口流量统计与限额脚本，支持 TCP/UDP、单端口和端口段。达到 IN + OUT 总限额后，由内核自动丢弃该端口后续流量，无需常驻轮询。

支持 Alpine（OpenRC）、Debian/Ubuntu（systemd）及 Debian SysV init；使用 `/bin/sh`，无需 bash、jq 或 bc。

## 安装

以 root 执行，自动安装依赖和开机服务：

```sh
wget -O- https://raw.githubusercontent.com/zhangx16/traffic-dog/main/install.sh | sh
```

GitHub raw 下载失败或返回 429 时使用 CDN：

```sh
wget -O- https://cdn.jsdelivr.net/gh/zhangx16/traffic-dog@main/install.sh | sh
```

也可用 `curl -fL URL | sh`。安装时可直接添加端口和限额：

```sh
wget -O- https://raw.githubusercontent.com/zhangx16/traffic-dog/main/install.sh | sh -s -- --limit 10G 80 443 10000-10100
```

安装选项：`--no-service` 跳过开机服务，`--no-deps` 跳过依赖安装，`--branch NAME` 指定分支，`--url URL` 指定脚本地址。

systemd 安装后启动服务，以启用当前会话的关机保存：

```sh
systemctl enable --now port-traffic-stat
```

Alpine 使用 `rc-service port-traffic-stat start`。

## 使用

运行 `port-traffic-stat` 进入交互菜单，也可使用以下命令：

| 命令（前缀均为 `port-traffic-stat`） | 功能 |
| --- | --- |
| `add 80 443 10000-10100` | 添加端口或端口段，支持逗号分隔 |
| `del 80` | 删除端口及其统计和限额 |
| `status` / `watch 2` | 查看统计 / 每 2 秒刷新 |
| `limit 80 10G` | 设置端口 IN + OUT 总限额 |
| `limit list` | 查看限额与使用量 |
| `unlimit 80` | 取消限额并恢复不限流 |
| `resume 80` / `resume all` | 保留限额，清零统计并恢复流量 |
| `reset 80` / `reset all` | 清零指定或全部端口统计与限额使用量 |
| `save` / `restore` | 保存当前计数 / 恢复规则 |
| `flush` | 保存统计并移除规则 |
| `install-service` | 安装开机服务 |
| `update` | 更新脚本 |
| `uninstall` | 卸载脚本与服务，保留数据 |

限额支持 `500M`、`10G`、`1T` 或纯字节数，按 1024 换算。更多命令见 `port-traffic-stat --help`。

## 统计与数据

- `IN`：目标端口流量（input/forward）；`OUT`：源端口流量（output/forward）；`TOTAL`：两者之和。
- `OPEN`：无限额；`LIMITED`：有限额；`PAUSED`：达到限额。
- `RESET_AT`：最近一次清零时间。
- 脚本路径：`/usr/local/bin/port-traffic-stat`。
- 数据目录：`/etc/port-traffic-stat/`，包含 `ports`、`state`、`limits`、`used`。

正常关机由已运行的服务保存统计，启动时恢复；当前没有定时保存，断电或强制重启会丢失上次保存后的数据。

脚本仅管理独立的 `inet port_traffic_stat` 表。其他防火墙工具若执行 `nft flush ruleset`，需重新运行 `port-traffic-stat restore`。端口统计不等同于网卡或云厂商账单，重叠端口范围可能重复计数。

## 测试

```sh
sh tests/regression.sh
```

测试不需要 root，不操作真实防火墙。覆盖计数保留、重复恢复、端口删除及参数校验；GitHub Actions 在 dash 和 BusyBox ash 下运行。真实内核限额行为需在 Linux 环境另行验证。

## 参考

- [zywe03/realm-xwPF](https://github.com/zywe03/realm-xwPF)
- [port-traffic-dog.sh](https://github.com/zywe03/realm-xwPF/blob/main/port-traffic-dog.sh)
- [nftables quota 文档](https://wiki.nftables.org/wiki-nftables/index.php/Quotas)
