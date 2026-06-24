# v2rayA 设备分流后台一键部署包

这个包用于在另一台 360T7 / OpenWrt / ImmortalWrt 设备上安装同一套功能：

- v2rayA Web 插件，默认端口 `2017`
- 本地设备分流后台，默认端口 `8088`
- 在线设备识别、节点一键导入、设备出口绑定
- 自动读取当前路由器 LAN 网段，不会把旧设备的 `192.168.6.1` 或 `192.168.1.1` 强行写到新路由
- 默认不复制旧设备的 MAC/IP 绑定，避免两台路由互相冲突

默认账号：

- 本地后台：`admin / weifeng`
- v2rayA 后台：默认是 `admin / weifeng`
- SSH 管理：`root / 1`

如果你后面手动改了 `2017` 的账号密码，可以直接在路由器里执行：

```sh
v2raya-sync-auth 新账号 新密码
```

这样 `8088` 后台会一起跟着改，不会再出现“2017 改了，8088 还在用旧密码”的情况。

## 最简单安装方式

当前仓库已经上传到：

```text
https://github.com/gaozhenxing3210/v2
```

在新路由 SSH 里直接执行：

```sh
wget -4 -O- https://cdn.jsdelivr.net/gh/gaozhenxing3210/v2@main/onekey.sh | sh
```

最短入口，带临时 DNS 提速：
```sh
sh -c "$(wget -4 -qO- https://cdn.jsdelivr.net/gh/gaozhenxing3210/v2@main/go.sh)"
```

如果没有 `wget`，但有 `curl`：

```sh
curl -4 -fsSL https://cdn.jsdelivr.net/gh/gaozhenxing3210/v2@main/onekey.sh | sh
```

这个一键脚本会从 GitHub 仓库下载 `dist/v2raya-policy-kit.tar.gz`，然后自动解压并执行安装。

默认行为：

- 恢复随包的 v2rayA 数据库：`RESTORE_V2RAYA_DB=1`
- 不恢复旧设备 MAC/IP 绑定：`RESTORE_DEVICE_MAP=0`
- 不修改 LAN IP 和网段
- 默认会把 `root` 密码设为 `1`

如果不想恢复 v2rayA 数据库，用：

```sh
RESTORE_V2RAYA_DB=0 wget -4 -O- https://cdn.jsdelivr.net/gh/gaozhenxing3210/v2@main/onekey.sh | sh
```

旧的源码包安装方式也可用：

```sh
GITHUB_REPO=gaozhenxing3210/v2 sh -c "$(wget -4 -O- https://cdn.jsdelivr.net/gh/gaozhenxing3210/v2@main/bootstrap.sh)"
```

通用格式是：

```sh
GITHUB_REPO=你的GitHub用户名/你的仓库名 sh -c "$(wget -O- https://raw.githubusercontent.com/你的GitHub用户名/你的仓库名/main/bootstrap.sh)"
```

如果路由里没有 `wget`，但有 `curl`：

```sh
GITHUB_REPO=你的GitHub用户名/你的仓库名 sh -c "$(curl -fsSL https://raw.githubusercontent.com/你的GitHub用户名/你的仓库名/main/bootstrap.sh)"
```

安装完成后访问：

```text
http://新路由IP:8088/
http://新路由IP:2017/
```

## 推荐的 GitHub Release 安装方式

如果你把 `v2raya-policy-kit.tar.gz` 上传到了 GitHub Release，可以用固定下载地址安装：

```sh
KIT_URL='https://github.com/你的GitHub用户名/你的仓库名/releases/latest/download/v2raya-policy-kit.tar.gz' sh -c "$(wget -O- https://raw.githubusercontent.com/你的GitHub用户名/你的仓库名/main/bootstrap.sh)"
```

Release 方式更适合带上 `ipks/` 里的 v2rayA 安装包，稳定性比只靠 OpenWrt 软件源更好。

## 离线安装

也可以把 `v2raya-policy-kit.tar.gz` 上传到新路由 `/tmp`，然后执行：

```sh
cd /tmp
tar -xzf v2raya-policy-kit.tar.gz
cd v2raya-policy-kit
sh install.sh
```

如果你通过 LuCI 页面上传，文件通常会在 `/tmp/upload/v2raya-policy-kit.tar.gz`，可以直接执行：

```sh
cd /tmp/upload
rm -rf v2raya-policy-kit v2-main
tar -xzf v2raya-policy-kit.tar.gz
INSTALL_SH="$(find . -name install.sh 2>/dev/null | head -n 1)"
cd "$(dirname "$INSTALL_SH")"
sh install.sh
```

也可以只下载仓库里的小脚本，让它自动使用 `/tmp/upload/v2raya-policy-kit.tar.gz` 并执行安装：

```sh
wget -O /tmp/run-local.sh https://raw.githubusercontent.com/gaozhenxing3210/v2/main/run-local.sh
sh /tmp/run-local.sh
```

如果包放在局域网电脑上，例如 `http://192.168.6.190:8899/v2raya-policy-kit.tar.gz`：

```sh
wget -O /tmp/run-local.sh https://raw.githubusercontent.com/gaozhenxing3210/v2/main/run-local.sh
KIT_URL='http://192.168.6.190:8899/v2raya-policy-kit.tar.gz' sh /tmp/run-local.sh
```

## 常用参数

默认安装不会改 LAN IP、不会改网段、不会恢复旧设备绑定。

```sh
# 清空新路由已有的后台设备绑定
RESET_DEVICE_MAP=1 sh install.sh

# 恢复随包的 v2rayA 节点数据库
RESTORE_V2RAYA_DB=1 sh install.sh

# 恢复随包的 v2rayA 数据库和设备绑定，不推荐给另一台路由直接用
RESTORE_FULL=1 sh install.sh

# 指定后台账号密码
PANEL_USER=admin PANEL_PASS=新密码 sh install.sh

# 指定 v2rayA API 登录账号密码
V2RAYA_USER=admin V2RAYA_PASS=weifeng sh install.sh
```

## 打包

在 Windows 工作区里运行：

```powershell
.\make-tar.ps1
```

会生成：

```text
D:\codex-shop\v2raya-policy-kit.tar
D:\codex-shop\v2raya-policy-kit.tar.gz
```

把 `.tar.gz` 上传到 GitHub Release 最方便。

## 安全默认值

给另一台 360T7 使用时，推荐保持默认：

- 不恢复 `/etc/v2raya-policy.map`
- 不改 `/etc/config/network`
- 不复制旧设备 MAC/IP 绑定
- 只复制后台功能、策略脚本、v2rayA 安装和可选节点数据库

这样两台设备可以在同一个环境里共存，不会因为绑定了同一个 IP 或旧设备 MAC 导致策略错乱。
