#!/usr/bin/env bash
# Bootstrap installer for acme-manager.

set -uo pipefail
umask 077

INSTALLER_VERSION="1.1.3"
DEFAULT_REPO="BBMCoin04/mb-acme"
REPO="${ACME_MANAGER_REPO:-$DEFAULT_REPO}"
REF="${ACME_MANAGER_REF:-main}"
INSTALL_PATH="${ACME_MANAGER_INSTALL_PATH:-/usr/local/sbin/acme-manager}"
QUICK_PATH="${ACME_MANAGER_QUICK_PATH:-/usr/local/bin/acme}"
COMPAT_PATH="${ACME_MANAGER_COMPAT_PATH:-/usr/local/bin/acme-manager}"
CACHE_BUST="$(date +%s)"
SOURCE_URL="${ACME_MANAGER_SOURCE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/acme-manager.sh?ts=${CACHE_BUST}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
BUNDLED_SOURCE=""
if [[ -z "${ACME_MANAGER_SOURCE_URL+x}" && -n "$SCRIPT_DIR" && -s "${SCRIPT_DIR}/acme-manager.sh" ]]; then
  BUNDLED_SOURCE="${SCRIPT_DIR}/acme-manager.sh"
fi
TEMP_FILE=""
BACKUP_FILE=""
QUICK_CREATED=0
COMPAT_CREATED=0
INSTALL_STARTED=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_CYAN=""
  C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

cleanup() {
  [[ -z "$TEMP_FILE" ]] || rm -f -- "$TEMP_FILE"
  [[ -z "$BACKUP_FILE" ]] || rm -f -- "$BACKUP_FILE"
}
trap cleanup EXIT

restore_manager() {
  if [[ -s "$BACKUP_FILE" ]]; then
    install -m 0755 "$BACKUP_FILE" "$INSTALL_PATH" || true
  else
    rm -f -- "$INSTALL_PATH"
  fi
}

rollback_install() {
  (( QUICK_CREATED == 0 )) || rm -f -- "$QUICK_PATH"
  (( COMPAT_CREATED == 0 )) || rm -f -- "$COMPAT_PATH"
  restore_manager
}

abort_install() {
  local exit_code="$1"
  (( INSTALL_STARTED == 0 )) || rollback_install
  exit "$exit_code"
}
trap 'abort_install 129' HUP
trap 'abort_install 130' INT
trap 'abort_install 143' TERM

if (( EUID != 0 )); then
  error "安装需要 root 权限，请在命令前使用 sudo。"
  exit 1
fi
if [[ "$INSTALL_PATH" != /* || ! "$INSTALL_PATH" =~ ^/[A-Za-z0-9._/@+:-]+$ || "$(basename "$INSTALL_PATH")" != "acme-manager" ]]; then
  error "管理器安装路径必须是仅含安全字符的绝对路径，并以 acme-manager 结尾。"
  exit 1
fi
if [[ "$QUICK_PATH" != /* || ! "$QUICK_PATH" =~ ^/[A-Za-z0-9._/@+:-]+$ || "$(basename "$QUICK_PATH")" != "acme" ]]; then
  error "主命令路径必须是仅含安全字符的绝对路径，并以 acme 结尾。"
  exit 1
fi
if [[ "$COMPAT_PATH" != /* || ! "$COMPAT_PATH" =~ ^/[A-Za-z0-9._/@+:-]+$ || "$(basename "$COMPAT_PATH")" != "acme-manager" ]]; then
  error "兼容命令路径必须是仅含安全字符的绝对路径，并以 acme-manager 结尾。"
  exit 1
fi

for command_name in install bash; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    error "缺少必要命令：${command_name}"
    exit 1
  fi
done
if [[ -z "$BUNDLED_SOURCE" && "$SOURCE_URL" != https://* ]]; then
  error "仅允许从 HTTPS 地址下载主程序。"
  exit 1
fi

TEMP_FILE="$(mktemp /tmp/acme-manager.XXXXXX.sh)" || exit 1
info "acme-manager 引导安装器 ${INSTALLER_VERSION}"
if [[ -n "$BUNDLED_SOURCE" ]]; then
  info "正在使用安装包内的 acme-manager.sh"
  cp -- "$BUNDLED_SOURCE" "$TEMP_FILE" || { error "无法读取安装包内的主程序。"; exit 1; }
else
  info "正在下载 ${SOURCE_URL}"
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$SOURCE_URL" -o "$TEMP_FILE"
    download_rc=$?
  else
    error "需要 curl 才能通过强制 HTTPS/TLS 下载安装。"
    exit 1
  fi
  (( download_rc == 0 )) || { error "下载失败，请检查仓库地址和网络。"; exit 1; }
fi

[[ -s "$TEMP_FILE" ]] || { error "下载结果为空，拒绝安装。"; exit 1; }
bash -n "$TEMP_FILE" || { error "下载的脚本未通过 Bash 语法检查，拒绝安装。"; exit 1; }
grep -q '^PROGRAM="acme-manager"$' "$TEMP_FILE" || { error "下载内容不是预期的 acme-manager 主程序，拒绝安装。"; exit 1; }
MANAGER_VERSION="$(awk -F '"' '/^VERSION="[0-9]/{print $2; exit}' "$TEMP_FILE")"
[[ "$MANAGER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { error "无法识别管理器版本，拒绝安装。"; exit 1; }
[[ "$MANAGER_VERSION" == "$INSTALLER_VERSION" ]] || {
  error "安装器版本 ${INSTALLER_VERSION} 与主程序版本 ${MANAGER_VERSION} 不一致，拒绝安装。"
  exit 1
}

install -d -m 0755 "$(dirname "$INSTALL_PATH")" "$(dirname "$QUICK_PATH")" "$(dirname "$COMPAT_PATH")" || exit 1
[[ ! -L "$INSTALL_PATH" ]] || { error "安装目标不能是软链接：${INSTALL_PATH}"; exit 1; }
for alias_path in "$QUICK_PATH" "$COMPAT_PATH"; do
  if [[ ( -e "$alias_path" || -L "$alias_path" ) && "$(readlink -f "$alias_path" 2>/dev/null || true)" != "$INSTALL_PATH" ]]; then
    error "命令路径已被其他程序占用，不会覆盖：${alias_path}"
    exit 1
  fi
done
if [[ -f "$INSTALL_PATH" ]]; then
  BACKUP_FILE="$(mktemp /tmp/acme-manager-existing.XXXXXX.sh)" || exit 1
  cp -a -- "$INSTALL_PATH" "$BACKUP_FILE" || exit 1
fi
INSTALL_STARTED=1
if ! install -m 0755 "$TEMP_FILE" "$INSTALL_PATH"; then
  rollback_install
  error "管理器安装失败，已尝试恢复原版本。"
  exit 1
fi
if [[ ! -e "$QUICK_PATH" && ! -L "$QUICK_PATH" ]]; then
  QUICK_CREATED=1
  if ! ln -s "$INSTALL_PATH" "$QUICK_PATH"; then
    rollback_install
    error "无法创建主命令 ${QUICK_PATH}。"
    exit 1
  fi
fi
if [[ ! -e "$COMPAT_PATH" && ! -L "$COMPAT_PATH" ]]; then
  COMPAT_CREATED=1
  if ! ln -s "$INSTALL_PATH" "$COMPAT_PATH"; then
    rollback_install
    error "无法创建兼容命令 ${COMPAT_PATH}。"
    exit 1
  fi
fi
if [[ "$(ACME_MANAGER_NO_MAIN=0 "$INSTALL_PATH" version 2>/dev/null)" != "acme-manager ${MANAGER_VERSION}" ]]; then
  rollback_install
  error "安装后的版本自检失败，已恢复原版本。"
  exit 1
fi
INSTALL_STARTED=0

hash_value="$(sha256sum "$INSTALL_PATH" 2>/dev/null | awk '{print $1}' || true)"
ok "acme-manager ${MANAGER_VERSION} 已安装到 ${INSTALL_PATH}"
ok "主命令：${QUICK_PATH} -> ${INSTALL_PATH}"
ok "兼容命令：${COMPAT_PATH} -> ${INSTALL_PATH}"
[[ -n "$hash_value" ]] && printf 'SHA-256: %s\n' "$hash_value"

cleanup
TEMP_FILE=""
BACKUP_FILE=""
trap - EXIT HUP INT TERM

if (( $# > 0 )); then
  exec "$INSTALL_PATH" "$@"
fi
if [[ -r /dev/tty && -w /dev/tty ]]; then
  exec "$INSTALL_PATH" </dev/tty >/dev/tty
fi
info "当前环境没有交互终端。稍后运行：sudo acme"
