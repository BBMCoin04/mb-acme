# acme-manager

Linux VPS 中文证书管理脚本，基于官方 `acme.sh`，用于申请、部署和续期 Let's Encrypt ECC 证书。当前版本：`2.3.3`。

## 安装

需要 root 权限：

```bash
curl -fsSLo /tmp/mb-acme-install.sh https://raw.githubusercontent.com/BBMCoin04/mb-acme/main/install.sh \
  && sudo bash /tmp/mb-acme-install.sh
```

以后运行 `sudo acme` 即可打开菜单。

## 第一次申请

1. 选择 `1 -> 2`，安装或升级 `acme.sh`，输入真实邮箱。
2. 回到主菜单，选择 `2`。
3. 输入主域名，例如 `example.com`。
4. 按需填写附加域名；不需要就留空。
5. 按需申请 `*.example.com` 泛域名。
6. 选择验证方式。
7. 签发成功后，可填写需要自动 reload 的 systemd 服务名，例如 `nginx`；不需要就留空。
8. 记下脚本显示的完整证书链和私钥路径。

如果仅服务 reload 失败，但证书文件已经写入，脚本会继续完成部署和续期配置，并提示你稍后手动 reload。

```text
1. 更新/维护
2. 申请并部署新证书
3. 查看证书与续期状态
4. 手动续期
5. 输出指定域名的证书路径
6. 查看最近日志
7. 高级维护
0. 退出
```

## 验证方式

- `standalone`：没有网站服务占用 80 端口时使用。
- `webroot`：已经运行 Nginx、Apache 或 Caddy，通常优先选它。
- `Cloudflare DNS API`：域名使用 Cloudflare。
- `DNSPod DNS API`：域名使用 DNSPod。
- `Aliyun DNS API`：域名使用阿里云 DNS。

泛域名必须使用 DNS API。DNS 凭据输入时不会显示，但 `acme.sh` 会把续期所需凭据保存在 root 专用配置中。

## 证书路径

每个主域名单独保存在 `/etc/acme/certs/<主域名>/`：

```text
cert.pem       单张证书
ca.pem         CA 证书
fullchain.pem  完整证书链，通常使用这个
key.pem        私钥
paths.env      路径变量
```

例如：

```text
/etc/acme/certs/example.com/fullchain.pem
/etc/acme/certs/example.com/key.pem
```

查询路径：

```bash
sudo acme paths example.com
sudo acme path example.com fullchain
sudo acme path example.com key
```

不要让 Nginx、Sing-box 等程序直接读取 `/root/.acme.sh` 中的内部文件。

## 续期与维护

首次成功部署后会自动配置续期：systemd 每 6 小时检查一次；非 systemd 系统使用已有的 `cron/crond`。已有 `acme.sh` cron 时不会重复创建任务。cron 未运行或状态无法检测时只会提示，不会阻断配置。

```bash
sudo acme status                 # 查看证书和续期状态
sudo acme renew-all              # 检查全部证书
sudo acme renew example.com      # 检查指定证书
sudo acme scheduler              # 安装或修复自动续期
sudo acme doctor                 # 运行诊断
```

只有排障时才使用 `sudo acme renew example.com --force`，否则可能触发 Let's Encrypt 限频。

更新管理器：菜单选择 `1 -> 1`。脚本会显示当前和远端版本；确有新版本时，按 Enter 后重新载入菜单。更新全部选择 `1 -> 3`。已有证书需要重新部署：菜单选择 `7 -> 1`，不必重新申请。

日志位于 `/var/log/acme-manager/renew.log`，超过 5 MiB 后自动保留最近 2000 行。

## 安全说明

- 私钥权限默认为 `0600`，不要改成全局可读。
- 不使用 `curl -k` 或 `--insecure`。
- 不修改 DNS、软件源、防火墙或其他网络配置。
- 不会强制结束占用 80 端口的进程。
- 不包含软件包缓存、Docker、journal 或临时文件清理功能。
- 个人使用默认信任 HTTPS 和 GitHub 仓库，不做签名校验；安装器仍会检查文件和 Bash 语法并输出 SHA-256。
