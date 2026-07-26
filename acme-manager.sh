#!/usr/bin/env bash
# acme-manager: a safe interactive manager for acme.sh on Linux VPS hosts.

set -uo pipefail
umask 077

VERSION="2.2.0"
PROGRAM="acme-manager"
INSTALL_PATH="${ACME_MANAGER_INSTALL_PATH:-/usr/local/sbin/acme-manager}"
MANAGER_REPO="${ACME_MANAGER_REPO:-BBMCoin04/mb-acme}"
MANAGER_REF="${ACME_MANAGER_REF:-main}"
MANAGER_RAW_BASE="https://raw.githubusercontent.com/${MANAGER_REPO}/${MANAGER_REF}"
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME_BIN="${ACME_HOME}/acme.sh"
CERT_ROOT="${CERT_ROOT:-/etc/acme/certs}"
LOG_ROOT="${LOG_ROOT:-/var/log/acme-manager}"
LOG_FILE="${LOG_ROOT}/renew.log"
LOCK_FILE="/run/lock/acme-manager.lock"
SERVER="letsencrypt"
SELF_PATH="${BASH_SOURCE[0]}"
if [[ -f "$SELF_PATH" ]]; then
  SELF_PATH="$(readlink -f "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")"
else
  SELF_PATH=""
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_BOLD=""
  C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

pause() {
  [[ -t 0 ]] || return 0
  read -r -p "按 Enter 键继续..." _
}

confirm() {
  local prompt="$1" answer
  read -r -p "${prompt} [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
  if (( EUID != 0 )); then
    error "此操作需要 root 权限，请使用 sudo 运行。"
    exit 1
  fi
}

ensure_directories() {
  install -d -m 0700 "$LOG_ROOT"
  install -d -m 0750 "$CERT_ROOT"
  install -d -m 0755 "$(dirname "$LOCK_FILE")"
}

have_acme() {
  [[ -x "$ACME_BIN" ]]
}

require_acme() {
  if ! have_acme; then
    error "尚未安装 acme.sh，请先在菜单中选择 '更新/维护 -> 安装或升级 acme.sh'。"
    return 1
  fi
}

validate_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_domain() {
  local domain="${1,,}" bare
  bare="${domain#\*.}"
  (( ${#bare} <= 253 )) || return 1
  [[ "$bare" == *.* ]] || return 1
  [[ "$bare" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  [[ ! "$bare" =~ \.[0-9]+$ ]]
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

install_dependencies() {
  local missing=() cmd manager
  for cmd in curl openssl socat flock; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) && return 0

  warn "缺少必要命令：${missing[*]}，准备安装依赖。"
  if command -v apt-get >/dev/null 2>&1; then
    manager="apt"
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl socat util-linux
  elif command -v dnf >/dev/null 2>&1; then
    manager="dnf"
    dnf install -y ca-certificates curl openssl socat util-linux
  elif command -v yum >/dev/null 2>&1; then
    manager="yum"
    yum install -y ca-certificates curl openssl socat util-linux
  elif command -v apk >/dev/null 2>&1; then
    manager="apk"
    apk add --no-cache bash ca-certificates curl openssl socat util-linux
  else
    error "无法识别包管理器，请手动安装：ca-certificates curl openssl socat util-linux"
    return 1
  fi

  for cmd in curl openssl socat flock; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "使用 ${manager} 安装依赖后仍缺少命令：${cmd}"
      return 1
    fi
  done
}

install_or_upgrade_acme() {
  local email installer
  require_root
  install_dependencies || return 1

  if have_acme; then
    info "当前版本：$($ACME_BIN --version 2>/dev/null | tail -n 1)"
    info "正在从 acme.sh 官方源升级..."
    if "$ACME_BIN" --upgrade --auto-upgrade 1; then
      ok "acme.sh 已升级，并已启用自动升级。"
      return 0
    fi
    error "acme.sh 升级失败，请检查网络和上方错误信息。"
    return 1
  fi

  while true; do
    read -r -p "请输入用于 ACME 账户通知的真实邮箱：" email
    if validate_email "$email"; then
      break
    fi
    error "邮箱格式不正确，不能使用随机或虚构邮箱。"
  done

  installer="$(mktemp /tmp/acme-install.XXXXXX.sh)" || return 1
  if ! curl --proto '=https' --tlsv1.2 -fsSL https://get.acme.sh -o "$installer"; then
    rm -f "$installer"
    error "无法从 https://get.acme.sh 下载官方安装器。"
    return 1
  fi

  info "正在安装 acme.sh 到 ${ACME_HOME}..."
  if sh "$installer" "email=${email}" --home "$ACME_HOME" --nocron --noprofile; then
    rm -f "$installer"
    if have_acme; then
      "$ACME_BIN" --set-default-ca --server "$SERVER" >/dev/null
      "$ACME_BIN" --upgrade --auto-upgrade 1 >/dev/null 2>&1 || true
      ok "acme.sh 安装成功。"
      return 0
    fi
  fi

  rm -f "$installer"
  error "acme.sh 安装失败。"
  return 1
}

update_manager() {
  local timestamp installer installer_url source_url rc
  require_root
  command -v curl >/dev/null 2>&1 || install_dependencies || return 1

  timestamp="$(date +%s)"
  installer_url="${MANAGER_RAW_BASE}/install.sh?ts=${timestamp}"
  source_url="${MANAGER_RAW_BASE}/acme-manager.sh?ts=${timestamp}"
  installer="$(mktemp /tmp/acme-manager-bootstrap.XXXXXX.sh)" || return 1

  info "正在检查 ${MANAGER_REPO}@${MANAGER_REF} 的管理器版本..."
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$installer_url" -o "$installer"; then
    rm -f "$installer"
    error "无法下载 GitHub 引导安装器。"
    return 1
  fi
  if ! bash -n "$installer" || ! grep -q '^# Bootstrap installer for acme-manager\.$' "$installer"; then
    rm -f "$installer"
    error "下载内容未通过安装器校验，拒绝更新。"
    return 1
  fi

  ACME_MANAGER_REPO="$MANAGER_REPO" \
    ACME_MANAGER_REF="$MANAGER_REF" \
    ACME_MANAGER_SOURCE_URL="$source_url" \
    ACME_MANAGER_INSTALL_PATH="$INSTALL_PATH" \
    bash "$installer" version
  rc=$?
  rm -f "$installer"

  if (( rc != 0 )); then
    error "acme-manager 更新失败。"
    return "$rc"
  fi
  ok "acme-manager 更新完成。"
}

install_manager_binary() {
  install -d -m 0755 "$(dirname "$INSTALL_PATH")"
  if [[ "$SELF_PATH" == "$INSTALL_PATH" ]]; then
    chmod 0755 "$INSTALL_PATH"
  elif [[ -n "$SELF_PATH" && -f "$SELF_PATH" ]]; then
    install -m 0755 "$SELF_PATH" "$INSTALL_PATH"
  else
    error "当前脚本来自临时数据流，无法安装自动续期所需的固定副本。"
    error "请改用仓库中的 install.sh 引导安装器。"
    return 1
  fi
}

native_acme_cron_present() {
  command -v crontab >/dev/null 2>&1 || return 1
  crontab -l 2>/dev/null | awk '
    /^[[:space:]]*#/ { next }
    /acme\.sh/ && /--cron/ && $6 != "root" { found=1 }
    END { exit !found }
  '
}

setup_scheduler() {
  require_root
  require_acme || return 1
  ensure_directories
  install_manager_binary || return 1

  if [[ ! -f /etc/systemd/system/acme-manager-renew.timer && ! -f /etc/cron.d/acme-manager ]] && native_acme_cron_present; then
    ok "检测到有效的 acme.sh 原生 cron，继续使用现有自动续期，不重复创建任务。"
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    cat > /etc/systemd/system/acme-manager-renew.service <<EOF
[Unit]
Description=Renew ACME certificates managed by acme-manager
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} renew-all --auto
EOF

    cat > /etc/systemd/system/acme-manager-renew.timer <<'EOF'
[Unit]
Description=Check ACME certificate renewal every six hours

[Timer]
OnCalendar=0/6:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    if systemctl daemon-reload && systemctl enable --now acme-manager-renew.timer; then
      rm -f /etc/cron.d/acme-manager
      ok "自动续期已启用：systemd timer 每 6 小时检查一次。"
      return 0
    fi
    error "systemd timer 配置失败。"
    return 1
  fi

  cat > /etc/cron.d/acme-manager <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root ${INSTALL_PATH} renew-all --auto
EOF
  chmod 0644 /etc/cron.d/acme-manager
  ok "自动续期已启用：cron 每天 03:17 检查一次。"
}

scheduler_status() {
  if command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/acme-manager-renew.timer ]]; then
    if systemctl is-enabled --quiet acme-manager-renew.timer 2>/dev/null; then
      printf '自动续期：systemd timer 已启用'
      if systemctl is-active --quiet acme-manager-renew.timer 2>/dev/null; then
        printf '，正在等待下次执行'
      fi
      printf '\n'
    else
      printf '自动续期：systemd timer 未启用\n'
    fi
  elif [[ -f /etc/cron.d/acme-manager ]]; then
    printf '自动续期：cron 已配置\n'
  elif native_acme_cron_present; then
    printf '自动续期：acme.sh 原生 cron 已配置\n'
  else
    printf '自动续期：未配置\n'
  fi
}

acquire_lock() {
  ensure_directories
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    warn "另一个申请或续期任务正在运行，本次操作退出。"
    return 1
  fi
}

log_command() {
  local mode="$1"
  shift
  ensure_directories
  printf '\n[%s] %s\n' "$(date '+%F %T %z')" "$*" >> "$LOG_FILE"

  if [[ "$mode" == "auto" || ! -t 1 ]]; then
    "$@" >> "$LOG_FILE" 2>&1
    return $?
  fi

  "$@" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

port_80_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR > 1 {addr=$4; sub(/%[^:]+/, "", addr); if (addr ~ /:80$/ || addr ~ /\]:80$/) found=1} END {exit !found}'
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:80 -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

show_port_80_owner() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | awk 'NR == 1 || $4 ~ /:80$|\]:80$/'
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:80 -sTCP:LISTEN 2>/dev/null || true
  fi
}

MAIN_DOMAIN=""
HAS_WILDCARD=0
declare -a ISSUE_DOMAINS=()

add_issue_domain() {
  local candidate="${1,,}" existing
  validate_domain "$candidate" || return 1
  for existing in "${ISSUE_DOMAINS[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  ISSUE_DOMAINS+=("$candidate")
  [[ "$candidate" == \*.* ]] && HAS_WILDCARD=1
}

collect_domains() {
  local input item
  ISSUE_DOMAINS=()
  HAS_WILDCARD=0

  while true; do
    read -r -p "主域名（例如 example.com，不含 *）：" MAIN_DOMAIN
    MAIN_DOMAIN="${MAIN_DOMAIN,,}"
    if [[ "$MAIN_DOMAIN" != \*.* ]] && validate_domain "$MAIN_DOMAIN"; then
      add_issue_domain "$MAIN_DOMAIN"
      break
    fi
    error "域名格式不正确；中文域名请先转换为 Punycode。"
  done

  read -r -p "附加域名/SAN（多个用逗号分隔，留空跳过）：" input
  if [[ -n "$input" ]]; then
    while IFS= read -r item; do
      item="$(trim "$item")"
      [[ -z "$item" ]] && continue
      if ! add_issue_domain "$item"; then
        error "附加域名格式不正确：${item}"
        return 1
      fi
    done < <(printf '%s' "$input" | tr ',' '\n')
  fi

  if confirm "是否同时申请 *.${MAIN_DOMAIN} 泛域名证书？"; then
    add_issue_domain "*.${MAIN_DOMAIN}"
  fi

  info "本次证书包含：${ISSUE_DOMAINS[*]}"
}

certificate_exists() {
  local domain="$1" cert_dir
  cert_dir="${ACME_HOME}/${domain}_ecc"
  [[ -s "${cert_dir}/${domain}.cer" && -s "${cert_dir}/fullchain.cer" && -s "${cert_dir}/${domain}.key" ]]
}

build_domain_args() {
  DOMAIN_ARGS=()
  local domain
  for domain in "${ISSUE_DOMAINS[@]}"; do
    DOMAIN_ARGS+=("-d" "$domain")
  done
}

declare -a DOMAIN_ARGS=()

run_issue_command() {
  local method="$1"
  shift
  local -a command=("$ACME_BIN" --issue --server "$SERVER" --keylength ec-256)
  command+=("${DOMAIN_ARGS[@]}")
  command+=("$@")
  info "开始使用 ${method} 验证申请证书。"
  log_command interactive "${command[@]}"
}

issue_standalone() {
  local service pre_hook post_hook
  if (( HAS_WILDCARD )); then
    error "HTTP-01 不支持泛域名证书，请选择 DNS API 模式。"
    return 1
  fi

  if port_80_in_use; then
    warn "TCP 80 端口已被占用，不会强制结束任何进程。"
    show_port_80_owner
    printf '可返回后改用 webroot/DNS API，或让 systemd 在验证前后停启一个服务。\n'
    read -r -p "需要自动停启的 systemd 服务名（例如 nginx；留空取消）：" service
    [[ -n "$service" ]] || return 1
    if [[ ! "$service" =~ ^[A-Za-z0-9@_.:-]+$ ]] || ! systemctl cat "$service" >/dev/null 2>&1; then
      error "systemd 服务不存在或名称无效：${service}"
      return 1
    fi
    pre_hook="systemctl stop ${service}"
    post_hook="systemctl start ${service}"
    run_issue_command "standalone" --standalone --pre-hook "$pre_hook" --post-hook "$post_hook"
    return $?
  fi

  run_issue_command "standalone" --standalone
}

issue_webroot() {
  local webroot
  if (( HAS_WILDCARD )); then
    error "HTTP-01 不支持泛域名证书，请选择 DNS API 模式。"
    return 1
  fi
  read -r -p "网站根目录（例如 /var/www/html）：" webroot
  if [[ "$webroot" != /* || ! -d "$webroot" ]]; then
    error "webroot 必须是已存在的绝对目录。"
    return 1
  fi
  if ! install -d -m 0755 "$webroot/.well-known/acme-challenge"; then
    error "无法创建 ACME challenge 目录。"
    return 1
  fi
  run_issue_command "webroot" --webroot "$webroot"
}

read_secret() {
  local prompt="$1" variable_name="$2" value
  read -r -s -p "$prompt" value
  printf '\n'
  if [[ -z "$value" ]]; then
    error "该凭据不能为空。"
    return 1
  fi
  printf -v "$variable_name" '%s' "$value"
  export "${variable_name?}"
}

issue_dns_cloudflare() {
  local CF_Token="" CF_Account_ID="" CF_Zone_ID="" rc
  printf 'Cloudflare Token 最少需要 Zone:DNS:Edit 与 Zone:Zone:Read 权限。\n'
  read_secret "Cloudflare API Token（输入不可见）：" CF_Token || return 1
  read -r -p "Account ID（建议填写）：" CF_Account_ID
  read -r -p "Zone ID（Token 仅限单个 Zone 时建议填写）：" CF_Zone_ID
  export CF_Token CF_Account_ID CF_Zone_ID
  run_issue_command "Cloudflare DNS API" --dns dns_cf
  rc=$?
  unset CF_Token CF_Account_ID CF_Zone_ID
  return "$rc"
}

issue_dns_dnspod() {
  local DP_Id="" DP_Key="" rc
  read -r -p "DNSPod API ID：" DP_Id
  [[ -n "$DP_Id" ]] || { error "API ID 不能为空。"; return 1; }
  read_secret "DNSPod API Key（输入不可见）：" DP_Key || return 1
  export DP_Id DP_Key
  run_issue_command "DNSPod DNS API" --dns dns_dp
  rc=$?
  unset DP_Id DP_Key
  return "$rc"
}

issue_dns_aliyun() {
  local Ali_Key="" Ali_Secret="" rc
  read -r -p "Aliyun AccessKey ID：" Ali_Key
  [[ -n "$Ali_Key" ]] || { error "AccessKey ID 不能为空。"; return 1; }
  read_secret "Aliyun AccessKey Secret（输入不可见）：" Ali_Secret || return 1
  export Ali_Key Ali_Secret
  run_issue_command "Aliyun DNS API" --dns dns_ali
  rc=$?
  unset Ali_Key Ali_Secret
  return "$rc"
}

choose_reload_command() {
  local service command
  printf '\n证书续期成功后可以自动 reload 服务。留空表示暂不配置。\n'
  read -r -p "systemd 服务名（例如 nginx、caddy、haproxy；留空跳过）：" service
  if [[ -z "$service" ]]; then
    RELOAD_COMMAND=""
    return 0
  fi
  if [[ ! "$service" =~ ^[A-Za-z0-9@_.:-]+$ ]] || ! systemctl cat "$service" >/dev/null 2>&1; then
    error "systemd 服务不存在或名称无效：${service}"
    return 1
  fi
  command="systemctl reload ${service}"
  RELOAD_COMMAND="$command"
}

RELOAD_COMMAND=""

emit_paths_env() {
  local domain="$1" cert_dir
  cert_dir="${CERT_ROOT}/${domain}"
  printf 'ACME_DOMAIN=%q\n' "$domain"
  printf 'ACME_CERT_FILE=%q\n' "$cert_dir/cert.pem"
  printf 'ACME_CA_FILE=%q\n' "$cert_dir/ca.pem"
  printf 'ACME_FULLCHAIN_FILE=%q\n' "$cert_dir/fullchain.pem"
  printf 'ACME_KEY_FILE=%q\n' "$cert_dir/key.pem"
}

write_paths_env() {
  local domain="$1" cert_dir
  cert_dir="${CERT_ROOT}/${domain}"
  emit_paths_env "$domain" > "$cert_dir/paths.env"
  chmod 0644 "$cert_dir/paths.env"
}

require_deployed_domain() {
  local domain="$1" cert_dir
  cert_dir="${CERT_ROOT}/${domain}"
  if [[ "$domain" == \*.* ]] || ! validate_domain "$domain"; then
    error "主域名格式不正确。"
    return 1
  fi
  if [[ ! -s "$cert_dir/fullchain.pem" || ! -s "$cert_dir/key.pem" ]]; then
    error "没有找到 ${domain} 的已部署证书。"
    return 1
  fi
}

show_paths() {
  local domain="${1,,}"
  require_deployed_domain "$domain" || return 1
  emit_paths_env "$domain"
}

show_single_path() {
  local domain="${1,,}" kind="$2" cert_dir
  require_deployed_domain "$domain" || return 1
  cert_dir="${CERT_ROOT}/${domain}"
  case "$kind" in
    cert) printf '%s/cert.pem\n' "$cert_dir" ;;
    ca) printf '%s/ca.pem\n' "$cert_dir" ;;
    fullchain|chain) printf '%s/fullchain.pem\n' "$cert_dir" ;;
    key|private-key) printf '%s/key.pem\n' "$cert_dir" ;;
    env) printf '%s/paths.env\n' "$cert_dir" ;;
    *) error "路径类型必须是 cert、ca、fullchain、key 或 env。"; return 2 ;;
  esac
}

print_integration_hint() {
  local domain="$1" cert_dir
  cert_dir="${CERT_ROOT}/${domain}"
  printf '\n%s给其他部署脚本使用%s\n' "$C_BOLD" "$C_RESET"
  printf '  环境文件：source %s/paths.env\n' "$cert_dir"
  printf '  完整证书：%s path %s fullchain\n' "$INSTALL_PATH" "$domain"
  printf '  私钥路径：%s path %s key\n' "$INSTALL_PATH" "$domain"
  printf '\nSing-box TLS 配置路径：\n'
  printf '  "certificate_path": "%s/fullchain.pem"\n' "$cert_dir"
  printf '  "key_path": "%s/key.pem"\n' "$cert_dir"
}

deploy_certificate() {
  local domain="$1" cert_dir rc
  cert_dir="${CERT_ROOT}/${domain}"
  install -d -m 0750 "$cert_dir"
  choose_reload_command || return 1

  local -a command=(
    "$ACME_BIN" --install-cert -d "$domain" --ecc
    --cert-file "$cert_dir/cert.pem"
    --key-file "$cert_dir/key.pem"
    --ca-file "$cert_dir/ca.pem"
    --fullchain-file "$cert_dir/fullchain.pem"
  )
  [[ -n "$RELOAD_COMMAND" ]] && command+=(--reloadcmd "$RELOAD_COMMAND")

  log_command interactive "${command[@]}"
  rc=$?
  if (( rc != 0 )); then
    error "证书部署失败；若只是 reload 服务失败，证书文件可能已经更新，请检查日志。"
    return "$rc"
  fi

  chmod 0600 "$cert_dir/key.pem"
  chmod 0644 "$cert_dir/cert.pem" "$cert_dir/ca.pem" "$cert_dir/fullchain.pem"
  ln -sfn fullchain.pem "$cert_dir/cert.crt"
  ln -sfn key.pem "$cert_dir/private.key"
  write_paths_env "$domain"

  ok "证书已部署到 ${cert_dir}"
  printf '  完整证书链：%s/fullchain.pem（兼容名 cert.crt）\n' "$cert_dir"
  printf '  私钥：      %s/key.pem（兼容名 private.key）\n' "$cert_dir"
}

issue_certificate() {
  local choice rc
  require_root
  require_acme || return 1
  install_dependencies || return 1
  collect_domains || return 1

  if certificate_exists "$MAIN_DOMAIN"; then
    warn "${MAIN_DOMAIN} 已有 ECC 证书记录，不会重复签发。"
    info "请使用 '重新部署已有证书'，或在手动续期菜单中操作。"
    return 1
  fi

  build_domain_args
  printf '\n验证方式：\n'
  printf '  1. standalone（80 端口空闲时使用）\n'
  printf '  2. webroot（已有 Web 服务，推荐）\n'
  printf '  3. Cloudflare DNS API（支持泛域名）\n'
  printf '  4. DNSPod DNS API（支持泛域名）\n'
  printf '  5. Aliyun DNS API（支持泛域名）\n'
  printf '  0. 返回\n'
  read -r -p "请选择：" choice

  acquire_lock || return 1
  case "$choice" in
    1) issue_standalone; rc=$? ;;
    2) issue_webroot; rc=$? ;;
    3) issue_dns_cloudflare; rc=$? ;;
    4) issue_dns_dnspod; rc=$? ;;
    5) issue_dns_aliyun; rc=$? ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac

  if (( rc != 0 )); then
    error "证书申请失败，未删除 acme.sh 的诊断记录。详情见 ${LOG_FILE}。"
    return "$rc"
  fi

  ok "证书签发成功。"
  deploy_certificate "$MAIN_DOMAIN" || return 1
  setup_scheduler || return 1
  print_integration_hint "$MAIN_DOMAIN"
}

deploy_existing() {
  local domain
  require_root
  require_acme || return 1
  read -r -p "输入 acme.sh 记录中的主域名：" domain
  domain="${domain,,}"
  if [[ "$domain" == \*.* ]] || ! validate_domain "$domain"; then
    error "主域名格式不正确。"
    return 1
  fi
  if ! certificate_exists "$domain"; then
    error "没有找到 ${domain} 的 ECC 证书记录。"
    "$ACME_BIN" --list || true
    return 1
  fi
  acquire_lock || return 1
  deploy_certificate "$domain" || return 1
  setup_scheduler || return 1
  print_integration_hint "$domain"
}

renew_all() {
  local mode="interactive" force=0 arg rc
  require_root
  require_acme || return 1
  for arg in "$@"; do
    case "$arg" in
      --auto) mode="auto" ;;
      --force) force=1 ;;
      *) error "未知参数：${arg}"; return 2 ;;
    esac
  done

  acquire_lock || return 0
  local -a command=("$ACME_BIN" --cron --home "$ACME_HOME")
  (( force )) && command+=(--force)

  if (( force )); then
    warn "强制续期会消耗 CA 限频额度。"
  elif [[ "$mode" == "interactive" ]]; then
    info "仅检查并续期已进入续期窗口的证书，不会强制重签。"
  fi

  log_command "$mode" "${command[@]}"
  rc=$?
  if (( rc == 0 )); then
    [[ "$mode" == "interactive" ]] && ok "续期检查完成。"
  else
    error "续期任务失败，详情见 ${LOG_FILE}。"
  fi
  return "$rc"
}

renew_domain() {
  local domain force="${2:-}"
  require_root
  require_acme || return 1
  domain="${1:-}"
  domain="${domain,,}"
  if [[ "$domain" == \*.* ]] || ! validate_domain "$domain"; then
    error "请提供证书记录中的主域名。"
    return 1
  fi
  if ! certificate_exists "$domain"; then
    error "没有找到 ${domain} 的 ECC 证书记录。"
    return 1
  fi

  acquire_lock || return 1
  local -a command=("$ACME_BIN" --renew -d "$domain" --ecc)
  [[ "$force" == "--force" ]] && command+=(--force)
  log_command interactive "${command[@]}"
}

manual_renew_menu() {
  local choice domain
  require_acme || return 1
  printf '\n手动续期：\n'
  printf '  1. 检查并续期所有到期证书（推荐）\n'
  printf '  2. 检查指定证书\n'
  printf '  3. 强制续期指定证书（可能触发限频）\n'
  printf '  0. 返回\n'
  read -r -p "请选择：" choice
  case "$choice" in
    1) renew_all ;;
    2)
      "$ACME_BIN" --list
      read -r -p "主域名：" domain
      renew_domain "$domain"
      ;;
    3)
      "$ACME_BIN" --list
      read -r -p "主域名：" domain
      warn "即将强制重签 ${domain}，Let’s Encrypt 对重复签发有速率限制。"
      if confirm "确定继续？"; then
        renew_domain "$domain" --force
      fi
      ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac
}

show_status() {
  local cert domain
  require_acme || return 1
  printf '\n%sacme.sh 证书记录%s\n' "$C_BOLD" "$C_RESET"
  "$ACME_BIN" --list || true
  printf '\n%s调度状态%s\n' "$C_BOLD" "$C_RESET"
  scheduler_status

  printf '\n%s已部署证书%s\n' "$C_BOLD" "$C_RESET"
  shopt -s nullglob
  local found=0
  for cert in "$CERT_ROOT"/*/fullchain.pem; do
    found=1
    domain="$(basename "$(dirname "$cert")")"
    printf '%s\n' "${domain}:"
    printf '  fullchain=%s/fullchain.pem\n' "$(dirname "$cert")"
    printf '  key=%s/key.pem\n' "$(dirname "$cert")"
    openssl x509 -in "$cert" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /' || warn "无法读取 ${cert}"
  done
  shopt -u nullglob
  (( found )) || printf '尚未在 %s 部署证书。\n' "$CERT_ROOT"
}

show_log() {
  if [[ -f "$LOG_FILE" ]]; then
    tail -n 100 "$LOG_FILE"
  else
    info "暂无续期日志。"
  fi
}

show_help() {
  cat <<EOF
${PROGRAM} ${VERSION}

用法：
  ${PROGRAM}                    打开交互菜单
  ${PROGRAM} update-manager     从 GitHub 更新 acme-manager
  ${PROGRAM} status             查看证书和自动续期状态
  ${PROGRAM} renew-all          检查并续期所有到期证书
  ${PROGRAM} renew-all --force  强制续期所有证书（谨慎使用）
  ${PROGRAM} renew DOMAIN       检查指定 ECC 证书
  ${PROGRAM} renew DOMAIN --force
  ${PROGRAM} scheduler          安装/修复自动续期任务
  ${PROGRAM} paths DOMAIN       输出可供 source 的证书路径变量
  ${PROGRAM} path DOMAIN TYPE   仅输出一个路径；TYPE: cert/ca/fullchain/key/env
  ${PROGRAM} install            安装或升级 acme.sh
  ${PROGRAM} version

证书默认部署到：${CERT_ROOT}/<主域名>/
自动续期日志：  ${LOG_FILE}
EOF
}

banner() {
  [[ -t 1 ]] && clear || true
  printf '%s%s' "$C_BOLD" "$C_CYAN"
  cat <<'EOF'
 __  __  ____           _      ____  __  __  _____
|  \/  || __ )         / \    / ___||  \/  || ____|
| |\/| ||  _ \  _____ / _ \  | |   | |\/| ||  _|
| |  | || |_) ||_____/ ___ \ | |___| |  | || |___
|_|  |_||____/      /_/   \_\ \____||_|  |_||_____|
EOF
  printf '%s' "$C_RESET"
  printf '%sacme-manager %s%s\n' "$C_BOLD" "$VERSION" "$C_RESET"
  printf "安全地申请、部署和续期 Let's Encrypt ECC 证书\n\n"
}

maintenance_menu() {
  local choice
  while true; do
    printf '\n更新/维护：\n'
    printf '  1. 更新 acme-manager\n'
    printf '  2. 安装/升级官方 acme.sh\n'
    printf '  3. 更新全部\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1)
        if update_manager; then
          info "正在重新载入最新版菜单..."
          exec "$INSTALL_PATH"
        fi
        pause
        ;;
      2) install_or_upgrade_acme; pause ;;
      3)
        if install_or_upgrade_acme && update_manager; then
          info "正在重新载入最新版菜单..."
          exec "$INSTALL_PATH"
        fi
        pause
        ;;
      0) return 0 ;;
      *) error "无效选项。" ;;
    esac
  done
}

advanced_menu() {
  local choice
  while true; do
    printf '\n高级维护：\n'
    printf '  1. 重新部署已有 acme.sh 证书\n'
    printf '  2. 安装/修复自动续期任务\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) deploy_existing; pause ;;
      2) setup_scheduler; pause ;;
      0) return 0 ;;
      *) error "无效选项。" ;;
    esac
  done
}

main_menu() {
  local choice domain
  require_root
  while true; do
    banner
    if have_acme; then
      printf 'acme.sh：已安装  '
      scheduler_status
    else
      printf 'acme.sh：未安装\n自动续期：未配置\n'
    fi
    printf '\n'
    printf '  1. 更新/维护\n'
    printf '  2. 申请并部署新证书\n'
    printf '  3. 查看证书与续期状态\n'
    printf '  4. 手动续期\n'
    printf '  5. 输出指定域名的证书路径\n'
    printf '  6. 查看最近日志\n'
    printf '  7. 高级维护\n'
    printf '  0. 退出\n'
    read -r -p "请选择：" choice
    printf '\n'
    case "$choice" in
      1) maintenance_menu ;;
      2) issue_certificate; pause ;;
      3) show_status; pause ;;
      4) manual_renew_menu; pause ;;
      5)
        read -r -p "主域名：" domain
        show_paths "$domain"
        pause
        ;;
      6) show_log; pause ;;
      7) advanced_menu ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

main() {
  local subcommand="${1:-menu}"
  case "$subcommand" in
    menu) main_menu ;;
    update-manager) update_manager ;;
    install) install_or_upgrade_acme ;;
    status) require_root; show_status ;;
    renew-all) shift; renew_all "$@" ;;
    renew) shift; renew_domain "${1:-}" "${2:-}" ;;
    scheduler) setup_scheduler ;;
    paths) require_root; show_paths "${2:-}" ;;
    path) require_root; show_single_path "${2:-}" "${3:-}" ;;
    version|--version|-v) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    help|--help|-h) show_help ;;
    *) error "未知命令：${subcommand}"; show_help; return 2 ;;
  esac
}

main "$@"
