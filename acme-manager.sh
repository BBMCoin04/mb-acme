#!/usr/bin/env bash
# acme-manager: a safe interactive manager for acme.sh on Linux VPS hosts.

set -uo pipefail
umask 077

VERSION="2.3.3"
PROGRAM="acme-manager"
INSTALL_PATH="${ACME_MANAGER_INSTALL_PATH:-/usr/local/sbin/acme-manager}"
QUICK_PATH="${ACME_MANAGER_QUICK_PATH:-/usr/local/bin/acme}"
COMPAT_PATH="${ACME_MANAGER_COMPAT_PATH:-/usr/local/bin/acme-manager}"
MANAGER_REPO="${ACME_MANAGER_REPO:-BBMCoin04/mb-acme}"
MANAGER_REF="${ACME_MANAGER_REF:-main}"
MANAGER_RAW_BASE="https://raw.githubusercontent.com/${MANAGER_REPO}/${MANAGER_REF}"
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME_BIN="${ACME_HOME}/acme.sh"
CERT_ROOT="${CERT_ROOT:-/etc/acme/certs}"
LOG_ROOT="${LOG_ROOT:-/var/log/acme-manager}"
LOG_FILE="${LOG_ROOT}/renew.log"
LOCK_FILE="${ACME_MANAGER_LOCK_FILE:-/run/lock/acme-manager.lock}"
SYSTEMD_UNIT_DIR="${ACME_MANAGER_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
RENEW_SERVICE_FILE="${SYSTEMD_UNIT_DIR}/acme-manager-renew.service"
RENEW_TIMER_FILE="${SYSTEMD_UNIT_DIR}/acme-manager-renew.timer"
CRON_FILE="${ACME_MANAGER_CRON_FILE:-/etc/cron.d/acme-manager}"
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
  install -d -m 0700 "$LOG_ROOT" &&
    install -d -m 0750 "$CERT_ROOT" &&
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
}

atomic_install_file() {
  local source="$1" target="$2" mode="$3" temporary
  temporary="$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX")" || return 1
  if ! install -m "$mode" "$source" "$temporary" || ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

validate_manager_paths() {
  [[ "$INSTALL_PATH" == /* && "$INSTALL_PATH" =~ ^/[A-Za-z0-9._/@+:-]+$ && "$(basename "$INSTALL_PATH")" == "acme-manager" ]] || {
    error "管理器安装路径必须是仅含安全字符的绝对路径，并以 acme-manager 结尾。"
    return 1
  }
  [[ "$QUICK_PATH" == /* && "$QUICK_PATH" =~ ^/[A-Za-z0-9._/@+:-]+$ && "$(basename "$QUICK_PATH")" == "acme" ]] || {
    error "主命令路径必须是仅含安全字符的绝对路径，并以 acme 结尾。"
    return 1
  }
  [[ "$COMPAT_PATH" == /* && "$COMPAT_PATH" =~ ^/[A-Za-z0-9._/@+:-]+$ && "$(basename "$COMPAT_PATH")" == "acme-manager" ]] || {
    error "兼容命令路径必须是仅含安全字符的绝对路径，并以 acme-manager 结尾。"
    return 1
  }
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
    if ! read -r -p "请输入用于 ACME 账户通知的真实邮箱：" email; then
      error "未读取到邮箱，已取消安装。"
      return 1
    fi
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
  if ! sh -n "$installer"; then
    rm -f -- "$installer"
    error "acme.sh 官方安装器未通过 Shell 语法检查，拒绝执行。"
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

download_manager_file() {
  local repo_path="$1" target="$2" timestamp="$3" api_url raw_url
  api_url="https://api.github.com/repos/${MANAGER_REPO}/contents/${repo_path}"
  raw_url="${MANAGER_RAW_BASE}/${repo_path}?ts=${timestamp}"

  if [[ "$MANAGER_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] &&
     curl --proto '=https' --tlsv1.2 --retry 2 --retry-delay 1 -fsSL \
       -H 'Accept: application/vnd.github.raw+json' \
       --get --data-urlencode "ref=${MANAGER_REF}" --data-urlencode "ts=${timestamp}" \
       "$api_url" -o "$target"; then
    return 0
  fi

  warn "GitHub API 下载失败，改用 Raw 地址重试。"
  curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$raw_url" -o "$target"
}

MANAGER_UPDATE_CHANGED=0

update_manager() {
  local timestamp update_dir installer source current_version remote_version installer_version installed_version rc
  require_root
  command -v curl >/dev/null 2>&1 || install_dependencies || return 1
  MANAGER_UPDATE_CHANGED=0

  timestamp="$(date +%s)"
  update_dir="$(mktemp -d /tmp/acme-manager-update.XXXXXX)" || return 1
  installer="${update_dir}/install.sh"
  source="${update_dir}/acme-manager.sh"
  current_version="$VERSION"
  if [[ -x "$INSTALL_PATH" ]]; then
    installed_version="$(ACME_MANAGER_NO_MAIN=0 "$INSTALL_PATH" version 2>/dev/null | awk '{print $2; exit}' || true)"
    [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && current_version="$installed_version"
  fi

  info "正在检查 ${MANAGER_REPO}@${MANAGER_REF}，当前版本 ${current_version}..."
  if ! download_manager_file install.sh "$installer" "$timestamp" ||
     ! download_manager_file acme-manager.sh "$source" "$timestamp"; then
    rm -rf -- "$update_dir"
    error "无法下载 acme-manager 更新文件。"
    return 1
  fi

  remote_version="$(awk -F '"' '/^VERSION="[0-9]/{print $2; exit}' "$source")"
  installer_version="$(awk -F '"' '/^INSTALLER_VERSION="[0-9]/{print $2; exit}' "$installer")"
  if ! bash -n "$installer" || ! grep -q '^# Bootstrap installer for acme-manager\.$' "$installer" ||
     ! bash -n "$source" || ! grep -q '^PROGRAM="acme-manager"$' "$source" ||
     [[ ! "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
     [[ "$installer_version" != "$remote_version" ]]; then
    rm -rf -- "$update_dir"
    error "远端更新文件版本不一致或校验失败，拒绝安装。"
    return 1
  fi

  info "远端版本：${remote_version}"
  if [[ "$remote_version" == "$current_version" ]]; then
    rm -rf -- "$update_dir"
    ok "acme-manager 已经是最新版 ${current_version}。"
    return 0
  fi

  (
    unset ACME_MANAGER_SOURCE_URL
    ACME_MANAGER_REPO="$MANAGER_REPO" \
      ACME_MANAGER_REF="$MANAGER_REF" \
      ACME_MANAGER_INSTALL_PATH="$INSTALL_PATH" \
      ACME_MANAGER_QUICK_PATH="$QUICK_PATH" \
      ACME_MANAGER_COMPAT_PATH="$COMPAT_PATH" \
      bash "$installer" version
  )
  rc=$?
  if (( rc != 0 )); then
    rm -rf -- "$update_dir"
    error "acme-manager 更新失败。"
    return "$rc"
  fi

  installed_version="$(ACME_MANAGER_NO_MAIN=0 "$INSTALL_PATH" version 2>/dev/null | awk '{print $2; exit}' || true)"
  rm -rf -- "$update_dir"
  if [[ "$installed_version" != "$remote_version" ]]; then
    error "安装后版本核对失败：期望 ${remote_version}，实际 ${installed_version:-未知}。"
    return 1
  fi

  MANAGER_UPDATE_CHANGED=1
  ok "acme-manager 已从 ${current_version} 更新到 ${installed_version}。"
}

install_command_alias() {
  local path="$1" label="$2"
  install -d -m 0755 "$(dirname "$path")" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    if [[ "$(readlink -f "$path" 2>/dev/null || true)" != "$INSTALL_PATH" ]]; then
      error "${label}路径已被其他程序占用：${path}"
      return 1
    fi
  else
    ln -s "$INSTALL_PATH" "$path" || return 1
  fi
}

install_manager_binary() {
  local installed_version=""
  validate_manager_paths || return 1
  install -d -m 0755 "$(dirname "$INSTALL_PATH")" || return 1
  if [[ "$SELF_PATH" == "$INSTALL_PATH" ]]; then
    chmod 0755 "$INSTALL_PATH" || return 1
  elif [[ -n "$SELF_PATH" && -f "$SELF_PATH" ]]; then
    if [[ -x "$INSTALL_PATH" ]]; then
      installed_version="$(ACME_MANAGER_NO_MAIN=0 "$INSTALL_PATH" version 2>/dev/null | awk '{print $2; exit}' || true)"
    fi
    if [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
       [[ "$(printf '%s\n' "$VERSION" "$installed_version" | sort -V | head -n 1)" == "$VERSION" ]] &&
       [[ "$installed_version" != "$VERSION" ]]; then
      warn "固定管理器 ${installed_version} 新于当前脚本 ${VERSION}，不会用旧脚本覆盖。"
    else
      atomic_install_file "$SELF_PATH" "$INSTALL_PATH" 0755 || return 1
    fi
  else
    error "当前脚本来自临时数据流，无法安装自动续期所需的固定副本。"
    error "请改用仓库中的 install.sh 引导安装器。"
    return 1
  fi
  install_command_alias "$QUICK_PATH" "主命令" || return 1
  install_command_alias "$COMPAT_PATH" "兼容命令" || return 1
}

native_acme_cron_present() {
  command -v crontab >/dev/null 2>&1 || return 1
  crontab -l 2>/dev/null | awk '
    /^[[:space:]]*#/ { next }
    /acme\.sh/ && /--cron/ && $6 != "root" { found=1 }
    END { exit !found }
  '
}

cron_daemon_state() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1
    return $?
  fi
  if command -v pidof >/dev/null 2>&1; then
    pidof cron >/dev/null 2>&1 || pidof crond >/dev/null 2>&1
    return $?
  fi
  return 2
}

warn_if_cron_not_running() {
  local rc
  cron_daemon_state
  rc=$?
  if (( rc == 1 )); then
    warn "续期任务已写入，但未检测到运行中的 cron/crond；请确认守护程序已启动。"
  elif (( rc == 2 )); then
    warn "续期任务已写入，但当前系统无法检测 cron/crond 是否正在运行。"
  fi
  return 0
}

print_cron_runtime_suffix() {
  local rc
  cron_daemon_state
  rc=$?
  case "$rc" in
    0) printf '\n' ;;
    1) printf '，但未检测到运行进程\n' ;;
    *) printf '，运行状态未知\n' ;;
  esac
}

setup_scheduler() {
  local service_candidate="" timer_candidate="" cron_candidate="" crond_help=""
  require_root
  require_acme || return 1
  ensure_directories || return 1
  install_manager_binary || return 1

  if [[ ! -f "$RENEW_TIMER_FILE" && ! -f "$CRON_FILE" ]] && native_acme_cron_present; then
    ok "检测到有效的 acme.sh 原生 cron，继续使用现有自动续期，不重复创建任务。"
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    install -d -m 0755 "$SYSTEMD_UNIT_DIR" || return 1
    service_candidate="$(mktemp /tmp/acme-renew-service.XXXXXX)" || return 1
    timer_candidate="$(mktemp /tmp/acme-renew-timer.XXXXXX)" || { rm -f -- "$service_candidate"; return 1; }
    cat > "$service_candidate" <<EOF
[Unit]
Description=Renew ACME certificates managed by acme-manager
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} renew-all --auto
EOF

    cat > "$timer_candidate" <<'EOF'
[Unit]
Description=Check ACME certificate renewal every six hours

[Timer]
OnCalendar=0/6:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    if atomic_install_file "$service_candidate" "$RENEW_SERVICE_FILE" 0644 &&
       atomic_install_file "$timer_candidate" "$RENEW_TIMER_FILE" 0644 &&
       systemctl daemon-reload && systemctl enable --now acme-manager-renew.timer; then
      rm -f -- "$service_candidate" "$timer_candidate" "$CRON_FILE"
      ok "自动续期已启用：systemd timer 每 6 小时检查一次。"
      return 0
    fi
    rm -f -- "$service_candidate" "$timer_candidate"
    error "systemd timer 配置失败。"
    return 1
  fi

  if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
    error "系统不使用 systemd，且未找到 cron/crond；无法启用自动续期。"
    error "请安装并启动 cron 守护程序后，再运行：acme scheduler"
    return 1
  fi

  if command -v crond >/dev/null 2>&1 && ! command -v cron >/dev/null 2>&1; then
    crond_help="$(crond --help 2>&1 || true)"
    if [[ "$crond_help" == *BusyBox* ]]; then
      info "检测到 BusyBox crond，改用 acme.sh 原生用户 crontab。"
      if "$ACME_BIN" --install-cronjob >/dev/null && native_acme_cron_present; then
        rm -f -- "$CRON_FILE"
        ok "自动续期已启用：acme.sh 原生 cron 每天检查一次。"
        warn_if_cron_not_running
        return 0
      fi
      error "无法为 BusyBox crond 安装 acme.sh 原生续期任务。"
      return 1
    fi
  fi

  install -d -m 0755 "$(dirname "$CRON_FILE")" || return 1
  cron_candidate="$(mktemp /tmp/acme-renew-cron.XXXXXX)" || return 1
  cat > "$cron_candidate" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root ${INSTALL_PATH} renew-all --auto
EOF
  if ! atomic_install_file "$cron_candidate" "$CRON_FILE" 0644; then
    rm -f -- "$cron_candidate"
    return 1
  fi
  rm -f -- "$cron_candidate"
  ok "自动续期已启用：cron 每天 03:17 检查一次。"
  warn_if_cron_not_running
}

scheduler_status() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system && -f "$RENEW_TIMER_FILE" ]]; then
    if systemctl is-enabled --quiet acme-manager-renew.timer 2>/dev/null; then
      printf '自动续期：systemd timer 已启用'
      if systemctl is-active --quiet acme-manager-renew.timer 2>/dev/null; then
        printf '，正在等待下次执行'
      fi
      printf '\n'
    else
      printf '自动续期：systemd timer 未启用\n'
    fi
  elif [[ -f "$CRON_FILE" ]]; then
    if command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; then
      printf '自动续期：cron 已配置'
      print_cron_runtime_suffix
    else
      printf '自动续期：cron 配置存在，但 cron/crond 缺失\n'
    fi
  elif native_acme_cron_present; then
    printf '自动续期：acme.sh 原生 cron 已配置'
    print_cron_runtime_suffix
  else
    printf '自动续期：未配置\n'
  fi
}

acquire_lock() {
  if ! ensure_directories || ! exec 9>"$LOCK_FILE"; then
    error "无法创建任务锁：${LOCK_FILE}"
    return 1
  fi
  if ! flock -n 9; then
    warn "另一个申请或续期任务正在运行，本次操作退出。"
    return 1
  fi
}

log_command() {
  local mode="$1" rc capture_file="${LOG_CAPTURE_FILE:-}"
  shift
  ensure_directories || return 1
  trim_manager_log_if_large || warn "无法轮转管理器日志，将继续执行证书命令。"
  printf '\n[%s] %s\n' "$(date '+%F %T %z')" "$*" >> "$LOG_FILE" || return 1

  if [[ "$mode" == "auto" || ! -t 1 ]]; then
    if [[ -n "$capture_file" ]]; then
      "$@" 2>&1 | tee -a "$LOG_FILE" "$capture_file" >/dev/null
      rc="${PIPESTATUS[0]}"
    else
      "$@" >> "$LOG_FILE" 2>&1
      rc=$?
    fi
  else
    if [[ -n "$capture_file" ]]; then
      "$@" 2>&1 | tee -a "$LOG_FILE" "$capture_file"
    else
      "$@" 2>&1 | tee -a "$LOG_FILE"
    fi
    rc="${PIPESTATUS[0]}"
  fi

  trim_manager_log_if_large || warn "无法轮转管理器日志。"
  return "$rc"
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
    if ! read -r -p "主域名（例如 example.com，不含 *）：" MAIN_DOMAIN; then
      error "未读取到主域名，已取消申请。"
      return 1
    fi
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
    if [[ ! "$service" =~ ^[A-Za-z0-9][A-Za-z0-9@_.:-]*$ ]] || ! systemctl cat "$service" >/dev/null 2>&1; then
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
  if [[ ! "$service" =~ ^[A-Za-z0-9][A-Za-z0-9@_.:-]*$ ]] || ! systemctl cat "$service" >/dev/null 2>&1; then
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
  emit_paths_env "$domain" > "$cert_dir/paths.env" && chmod 0644 "$cert_dir/paths.env"
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
  printf '  完整证书：%s path %s fullchain\n' "$QUICK_PATH" "$domain"
  printf '  私钥路径：%s path %s key\n' "$QUICK_PATH" "$domain"
  printf '\nSing-box TLS 配置路径：\n'
  printf '  "certificate_path": "%s/fullchain.pem"\n' "$cert_dir"
  printf '  "key_path": "%s/key.pem"\n' "$cert_dir"
}

deploy_certificate() {
  local domain="$1" cert_dir rc output_file reload_failed=0
  cert_dir="${CERT_ROOT}/${domain}"
  if ! install -d -m 0750 "$cert_dir"; then
    error "无法创建证书部署目录：${cert_dir}"
    return 1
  fi
  choose_reload_command || return 1

  local -a command=(
    "$ACME_BIN" --install-cert -d "$domain" --ecc
    --cert-file "$cert_dir/cert.pem"
    --key-file "$cert_dir/key.pem"
    --ca-file "$cert_dir/ca.pem"
    --fullchain-file "$cert_dir/fullchain.pem"
  )
  [[ -n "$RELOAD_COMMAND" ]] && command+=(--reloadcmd "$RELOAD_COMMAND")

  ensure_directories || return 1
  output_file="$(mktemp "${LOG_ROOT}/.deploy-output.XXXXXX")" || return 1
  LOG_CAPTURE_FILE="$output_file" log_command interactive "${command[@]}"
  rc=$?
  if (( rc != 0 )); then
    if [[ -n "$RELOAD_COMMAND" ]] &&
       grep -Fq 'Reload error for:' "$output_file" &&
       [[ -s "$cert_dir/cert.pem" && -s "$cert_dir/key.pem" &&
          -s "$cert_dir/ca.pem" && -s "$cert_dir/fullchain.pem" ]]; then
      reload_failed=1
      warn "证书文件已写入，但服务 reload 失败；将继续完成部署和续期配置。"
    else
      rm -f -- "$output_file"
      error "证书部署失败，请检查日志：${LOG_FILE}"
      return "$rc"
    fi
  fi
  rm -f -- "$output_file"

  if ! chmod 0600 "$cert_dir/key.pem" ||
     ! chmod 0644 "$cert_dir/cert.pem" "$cert_dir/ca.pem" "$cert_dir/fullchain.pem" ||
     ! ln -sfn fullchain.pem "$cert_dir/cert.crt" ||
     ! ln -sfn key.pem "$cert_dir/private.key" ||
     ! write_paths_env "$domain"; then
    error "证书文件已写入，但权限、兼容链接或路径文件配置失败。"
    return 1
  fi

  ok "证书已部署到 ${cert_dir}"
  printf '  完整证书链：%s/fullchain.pem（兼容名 cert.crt）\n' "$cert_dir"
  printf '  私钥：      %s/key.pem（兼容名 private.key）\n' "$cert_dir"
  if (( reload_failed )); then
    warn "请修复服务配置后手动执行：${RELOAD_COMMAND}"
  fi
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
  [[ -z "$force" || "$force" == "--force" ]] || { error "未知参数：${force}"; return 2; }
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

trim_manager_log_if_large() {
  local size temporary
  [[ -f "$LOG_FILE" ]] || return 0
  size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf '0')"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  (( size > 5 * 1024 * 1024 )) || return 0
  temporary="$(mktemp "${LOG_ROOT}/.renew-log.XXXXXX")" || return 1
  if ! tail -n 2000 "$LOG_FILE" > "$temporary" || ! atomic_install_file "$temporary" "$LOG_FILE" 0600; then
    rm -f -- "$temporary"
    return 1
  fi
  rm -f -- "$temporary"
  ok "管理器续期日志超过 5 MiB，已保留最近 2000 行。"
}

doctor() {
  local installed_version="未安装" installed_hash="未知" quick_target="不存在" compat_target="不存在"
  local acme_version="未安装" cert_count=0 log_size=0
  [[ ! -x "$INSTALL_PATH" ]] || installed_version="$(ACME_MANAGER_NO_MAIN=0 "$INSTALL_PATH" version 2>/dev/null || printf '无法执行')"
  [[ ! -f "$INSTALL_PATH" ]] || installed_hash="$(sha256sum "$INSTALL_PATH" 2>/dev/null | awk '{print $1}' || printf '未知')"
  [[ ! -e "$QUICK_PATH" && ! -L "$QUICK_PATH" ]] || quick_target="$(readlink -f "$QUICK_PATH" 2>/dev/null || printf '无法解析')"
  [[ ! -e "$COMPAT_PATH" && ! -L "$COMPAT_PATH" ]] || compat_target="$(readlink -f "$COMPAT_PATH" 2>/dev/null || printf '无法解析')"
  if have_acme; then
    acme_version="$($ACME_BIN --version 2>/dev/null | tail -n 1 || printf '无法读取')"
  fi
  if [[ -d "$CERT_ROOT" ]]; then
    cert_count="$(find "$CERT_ROOT" -mindepth 2 -maxdepth 2 -type f -name fullchain.pem 2>/dev/null | wc -l)"
  fi
  [[ ! -f "$LOG_FILE" ]] || log_size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf '0')"

  printf '管理器当前进程：%s %s\n' "$PROGRAM" "$VERSION"
  printf '固定安装文件：%s（%s）\n' "$INSTALL_PATH" "$installed_version"
  printf '主命令目标：%s -> %s\n' "$QUICK_PATH" "$quick_target"
  printf '兼容命令目标：%s -> %s\n' "$COMPAT_PATH" "$compat_target"
  printf '安装文件 SHA-256：%s\n' "$installed_hash"
  printf 'acme.sh：%s\n' "$acme_version"
  printf '证书目录：%s（已部署 %s 张）\n' "$CERT_ROOT" "$cert_count"
  printf '续期日志：%s（%s 字节）\n' "$LOG_FILE" "$log_size"
  scheduler_status
  printf '命令解析：\n'
  type -a acme 2>/dev/null || true
  type -a acme-manager 2>/dev/null || true
}

show_help() {
  cat <<EOF
${PROGRAM} ${VERSION}

用法：
  acme                    打开交互菜单
  acme update-manager     从 GitHub 更新 acme-manager
  acme status             查看证书和自动续期状态
  acme renew-all          检查并续期所有到期证书
  acme renew-all --force  强制续期所有证书（谨慎使用）
  acme renew DOMAIN       检查指定 ECC 证书
  acme renew DOMAIN --force
  acme scheduler          安装/修复自动续期任务
  acme paths DOMAIN       输出可供 source 的证书路径变量
  acme path DOMAIN TYPE   仅输出一个路径；TYPE: cert/ca/fullchain/key/env
  acme doctor             检查版本、命令入口和续期状态
  acme install            安装或升级 acme.sh
  acme version

兼容命令：acme-manager

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
    if ! read -r -p "请选择：" choice; then
      printf '\n'
      return 0
    fi
    case "$choice" in
      1)
        if update_manager && (( MANAGER_UPDATE_CHANGED )); then
          info "按 Enter 键后重新载入新版菜单。"
          pause
          exec "$INSTALL_PATH"
        fi
        pause
        ;;
      2) install_or_upgrade_acme; pause ;;
      3)
        if install_or_upgrade_acme && update_manager && (( MANAGER_UPDATE_CHANGED )); then
          info "按 Enter 键后重新载入新版菜单。"
          pause
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
    printf '  3. 运行安装与续期诊断\n'
    printf '  0. 返回\n'
    if ! read -r -p "请选择：" choice; then
      printf '\n'
      return 0
    fi
    case "$choice" in
      1) deploy_existing; pause ;;
      2) setup_scheduler; pause ;;
      3) doctor; pause ;;
      0) return 0 ;;
      *) error "无效选项。" ;;
    esac
  done
}

main_menu() {
  local choice domain
  require_root
  install_manager_binary || return 1
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
    if ! read -r -p "请选择：" choice; then
      printf '\n'
      return 0
    fi
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
    doctor) require_root; doctor ;;
    paths) require_root; show_paths "${2:-}" ;;
    path) require_root; show_single_path "${2:-}" "${3:-}" ;;
    version|--version|-v) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    help|--help|-h) show_help ;;
    *) error "未知命令：${subcommand}"; show_help; return 2 ;;
  esac
}

if [[ "${ACME_MANAGER_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
