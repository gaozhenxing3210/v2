# v2rayA 设备分流后台一键部署包

这个包用于在另一台 360T7 / OpenWrt / ImmortalWrt 设备上安装同一套功能：

- v2rayA Web 插件，默认端口 `2017`
- 本地设备分流后台，默认端口 `8088`
- 在线设备识别、节点一键导入、设备出口绑定
- 自动读取当前路由器 LAN 网段，不会把旧设备的 `192.168.6.1` 或 `192.168.1.1` 强行写到新路由
- 默认不复制旧设备的 MAC/IP 绑定，避免两台路由互相冲突

默认账号：

- 本地后台：`admin / admin`
- v2rayA 后台：如果恢复了随包数据库，一般是 `admin / weifeng`

## 最简单安装方式

把本仓库上传到 GitHub 后，在新路由 SSH 里执行：

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
