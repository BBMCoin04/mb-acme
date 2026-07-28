# acme-manager

Linux VPS 中文证书管理脚本，基于官方 `acme.sh`，用于申请、部署、续期和删除 Let's Encrypt ECC 证书。当前版本：`1.1.1`。

## 安装

需要 root 权限和 `curl`：

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

如果仅服务 reload 失败，但证书文件已经写入，脚本会继续完成部署和续期配置，并提示稍后手动 reload。

```text
1. 更新/维护
2. 申请并部署新证书
3. 查看证书与续期状态
4. 手动续期
5. 彻底删除证书
6. 输出指定域名的证书路径
7. 查看最近日志
8. 高级维护
0. 退出
```

## 验证方式

- `standalone`：HTTP-01。申请和续签时可临时停止占用 80 端口的 systemd 服务。
- `webroot`：由现有 Nginx、Apache 或 Caddy 提供 challenge，通常无停机，优先推荐。
- `Cloudflare DNS API`：域名使用 Cloudflare，支持泛域名。
- `DNSPod DNS API`：域名使用 DNSPod，支持泛域名。
- `Aliyun DNS API`：域名使用阿里云 DNS，支持泛域名。

泛域名必须使用 DNS API。DNS 凭据输入时不会显示，但 `acme.sh` 会把续签所需凭据保存在 root 专用配置中。

## 80 端口临时避让

可行，而且不需要长期空置 80 端口。选择 `standalone` 后，脚本会：

1. 显示当前 80 端口监听者，并尝试从进程 cgroup 识别 systemd 服务。
2. 接受一个或多个服务名，例如 `nginx caddy`；识别成功时直接回车可采用建议值。
3. 通过 acme.sh `pre-hook` 只停止当时处于 active 状态的已配置服务。
4. 再次检查 80 端口；如果仍有未知监听者，立即恢复已停服务并终止签发。
5. 在验证成功或失败后通过 `post-hook` 恢复本次实际停止的服务。
6. 将钩子保存到证书续签配置，今后的 `renew` 和定时 `cron` 同样执行。

管理器还保存临时恢复状态，并在 ACME 命令异常结束时做兜底恢复。若进程被 `SIGKILL` 或机器在验证期间异常掉电，可执行：

```bash
sudo acme port80-restore
```

限制和前提：

- 域名的 A/AAAA 记录必须指向这台服务器；错误的 AAAA 记录也可能导致验证失败。
- 公网 TCP 80 必须能到达服务器，云安全组、防火墙和 NAT 不能拦截。
- HTTP-01 不支持 `*.example.com` 泛域名。
- 只管理明确指定的 systemd 服务，不会 `kill` 未知 PID。
- 拒绝停止 `docker`、`containerd`、`podman` 或 `kubelet` 整体，避免中断所有容器。
- 如果 80 端口由容器直接发布，优先用反向代理加 webroot，或把单个容器封装成独立 systemd 服务。
- 停止服务期间会有几秒钟 HTTP 中断；需要零停机时使用 webroot。

## 彻底删除证书

主菜单选择 `5`，或运行：

```bash
sudo acme delete example.com
```

删除前必须再次输入完整主域名确认。脚本按以下顺序执行：

1. 调用 `acme.sh --remove -d example.com --ecc`，从自动续签列表移除证书。
2. 删除 `/root/.acme.sh/example.com_ecc/` 中 acme.sh 默认保留的配置、证书、私钥和签发残留。
3. 删除 `/etc/acme/certs/example.com/` 中的部署副本、私钥、兼容链接和 `paths.env`。
4. 检查两个目录都已消失。

删除不可撤销。使用这些文件的 Nginx、Sing-box 等服务可能继续持有内存中的旧证书，但会在下次 reload/restart 时因路径不存在而失败，请先修改对应服务配置。

删除单张证书不会删除共享 ACME 账户、其他证书、全局续签 timer/cron 或共享审计日志。

## 证书路径

每个主域名单独保存在 `/etc/acme/certs/<主域名>/`：

```text
cert.pem       单张证书
ca.pem         CA 证书
fullchain.pem  完整证书链，通常使用这个
key.pem        私钥
paths.env      路径变量
```

查询路径：

```bash
sudo acme paths example.com
sudo acme path example.com fullchain
sudo acme path example.com key
```

不要让 Nginx、Sing-box 等程序直接读取 `/root/.acme.sh` 中的内部文件。

## 续期与维护

首次成功部署后会自动配置续期：systemd 每 6 小时检查一次；非 systemd 系统使用已有的 `cron/crond`。已有 `acme.sh` cron 时不会重复创建任务。

```bash
sudo acme status                 # 查看证书和续期状态
sudo acme renew-all              # 检查全部证书
sudo acme renew example.com      # 检查指定证书
sudo acme scheduler              # 安装或修复自动续期
sudo acme doctor                 # 运行诊断
```

只有排障时才使用 `sudo acme renew example.com --force`，否则可能触发 Let's Encrypt 限频。

更新管理器：菜单选择 `1 -> 1`。更新全部选择 `1 -> 3`。已有证书需要重新部署：菜单选择 `8 -> 1`，不必重新申请。

日志位于 `/var/log/acme-manager/renew.log`，超过 5 MiB 后自动保留最近 2000 行。

## 安全说明

- 私钥权限默认为 `0600`，不要改成全局可读。
- 不使用 `curl -k`、`--insecure` 或明文 HTTP 下载。
- 不修改 DNS、软件源、防火墙或其他网络配置。
- 不会强制结束占用 80 端口的未知进程。
- 删除操作要求完整域名二次确认，并受全局任务锁保护。
- 不包含软件包缓存、Docker、journal 或无关临时文件清理功能。
- 安装和在线更新信任 HTTPS、GitHub 仓库及 acme.sh 官方安装地址；当前没有独立代码签名。安装器仍会检查脚本标识、版本一致性和 Bash 语法，并输出安装文件 SHA-256。
