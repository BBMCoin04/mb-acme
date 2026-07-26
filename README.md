# mb-acme / acme-manager

面向 Linux VPS 的交互式 ACME 证书管理工具。基于官方 acme.sh，负责申请、部署、自动续期、手动续期和向其他部署脚本提供稳定的证书路径。

## 一行安装

推荐方式（先下载、再执行，便于检查和排错）：

```bash
curl -fsSLo /tmp/mb-acme-install.sh https://raw.githubusercontent.com/BBMAPI/mb-acme/main/install.sh && sudo bash /tmp/mb-acme-install.sh
```

快速方式：

```bash
curl -fsSL https://raw.githubusercontent.com/BBMAPI/mb-acme/main/install.sh | sudo bash
```

使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/BBMAPI/mb-acme/main/install.sh | sudo bash
```

`install.sh` 会执行以下步骤：

1. 只允许从 HTTPS 地址下载。
2. 将主程序下载到临时文件。
3. 检查文件非空、程序标识和 Bash 语法。
4. 安装为 `/usr/local/sbin/acme-manager`。
5. 输出安装文件的 SHA-256（系统支持时）。
6. 重新连接当前终端并打开交互菜单。

不要绕过安装器直接运行 `bash <(curl .../acme-manager.sh)`。进程替换产生的临时文件不能可靠地保存为 systemd 自动续期程序。

## 使用流程

新 VPS 推荐按以下顺序操作：

1. 执行一行安装命令。
2. 菜单选择 `1`，安装 acme.sh，并输入真实邮箱。
3. 菜单选择 `2`，输入主域名、附加域名和是否申请泛域名。
4. 选择 standalone、webroot 或 DNS API 验证。
5. 签发成功后，按提示决定是否配置服务自动 reload。
6. 记录脚本输出的完整证书链和私钥路径。
7. 部署 Nginx、Caddy、Sing-box 等应用，直接引用这些路径。

每一步都有中文提示、输入说明、成功/失败状态和错误去向。签发、部署和续期的详细输出会记录到：

```text
/var/log/acme-manager/renew.log
```

重新打开菜单：

```bash
sudo acme-manager
```

## 支持的验证方式

- `standalone`：TCP 80 必须可从公网访问。端口被占用时不会强杀进程，可选择通过 acme.sh hook 停启指定 systemd 服务。
- `webroot`：适合已经运行 Nginx、Apache 或 Caddy 的 VPS，通常是 HTTP 场景的推荐方式。
- `Cloudflare DNS API`：使用最小权限 API Token，支持 CDN 代理和泛域名。
- `DNSPod DNS API`：使用 API ID 和 API Key，支持泛域名。
- `Aliyun DNS API`：使用 AccessKey ID 和 AccessKey Secret，支持泛域名。

泛域名证书必须使用 DNS API。DNS 验证不要求 A/AAAA 记录指向本机。

## 固定证书路径

每张证书按主域名单独部署：

```text
/etc/acme/certs/<主域名>/cert.pem
/etc/acme/certs/<主域名>/ca.pem
/etc/acme/certs/<主域名>/fullchain.pem
/etc/acme/certs/<主域名>/key.pem
/etc/acme/certs/<主域名>/paths.env
```

兼容文件名：

```text
/etc/acme/certs/<主域名>/cert.crt -> fullchain.pem
/etc/acme/certs/<主域名>/private.key -> key.pem
```

不要让应用直接读取 `/root/.acme.sh` 中的内部文件。acme.sh 续期成功后会自动更新 `/etc/acme/certs` 中的生产文件，并执行已配置的 reload 命令。

## 给其他脚本调用

输出一个域名的全部路径变量：

```bash
sudo acme-manager paths example.com
```

输出格式稳定，可直接加载：

```bash
source "$(sudo acme-manager path example.com env)"
printf '%s\n' "$ACME_FULLCHAIN_FILE"
printf '%s\n' "$ACME_KEY_FILE"
```

只取得一个路径：

```bash
sudo acme-manager path example.com fullchain
sudo acme-manager path example.com key
```

支持的路径类型：`cert`、`ca`、`fullchain`、`key`、`env`。目标证书不存在时命令返回非零状态，方便下游脚本立即终止。

### Sing-box 脚本示例

部署脚本以 root 运行时：

```bash
DOMAIN="example.com"
CERT_FILE="$(acme-manager path "$DOMAIN" fullchain)"
KEY_FILE="$(acme-manager path "$DOMAIN" key)"

[[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || {
  echo "证书或私钥不存在" >&2
  exit 1
}
```

写入 Sing-box JSON 时使用：

```json
{
  "tls": {
    "enabled": true,
    "certificate_path": "/etc/acme/certs/example.com/fullchain.pem",
    "key_path": "/etc/acme/certs/example.com/key.pem"
  }
}
```

私钥默认权限为 `0600`。如果 Sing-box 使用非 root 用户运行，应通过专用用户组授予最小读取权限，不要把私钥改成全局可读。

## 自动与手动续期

首次成功部署后会自动配置续期：

- systemd 系统：每 6 小时检查一次，附加最多 1 小时随机延迟。
- 非 systemd 系统：通过 `/etc/cron.d/acme-manager` 每天 `03:17` 检查。
- 已有有效 acme.sh 原生 cron：直接复用，不创建重复任务。

acme.sh 只会续期已经进入续期窗口的证书，不会每次检查都重新签发。

常用命令：

```bash
sudo acme-manager status
sudo acme-manager renew-all
sudo acme-manager renew example.com
sudo acme-manager scheduler
```

强制续期只用于排障或验证部署链路，可能消耗 CA 的重复签发额度：

```bash
sudo acme-manager renew example.com --force
```

## 从旧版迁移

1. 打开菜单并选择“查看证书与续期状态”。
2. 如果 acme.sh 列表中已有域名，选择“重新部署已有 acme.sh 证书”。
3. 输入列表中的 `Main_Domain`，无需重新签发。
4. 更新应用配置，改用 `/etc/acme/certs/<主域名>/fullchain.pem` 和 `key.pem`。
5. 验证应用加载新证书后，再移除旧 `/root/mbca` 路径引用。

旧脚本可能在 root 用户 crontab 中留下包含 `root bash ~/.acme.sh/acme.sh --cron` 的无效条目。新程序能识别它不是有效的用户 cron，但不会擅自修改已有 crontab；迁移确认后可用 `sudo crontab -e` 手动删除。

## 安全变化

- 不使用 `curl -k` 或 acme.sh `--insecure`。
- 不修改 `/etc/resolv.conf`、WARP、系统软件源或网络配置。
- 不使用 `kill -9` 清空 80 端口。
- 不生成虚假邮箱。
- 不在每次签发前卸载重装 acme.sh。
- Cloudflare 使用 API Token，不要求 Global API Key。
- DNS 凭据输入时不回显，也不会写入命令参数和管理器日志。
- 每个域名单独保存，避免多张证书覆盖同一文件。

## 仓库文件

```text
mb-acme/
├── README.md
├── install.sh
└── acme-manager.sh
```

建议为稳定版本创建 Git tag。安装指定版本时：

```bash
curl -fsSL https://raw.githubusercontent.com/BBMAPI/mb-acme/main/install.sh | sudo env ACME_MANAGER_REF=v2.1.0 bash
```

也可以在 fork 中覆盖默认仓库：

```bash
curl -fsSL https://raw.githubusercontent.com/BBMAPI/mb-acme/main/install.sh | sudo env ACME_MANAGER_REPO=OWNER/REPO bash
```
