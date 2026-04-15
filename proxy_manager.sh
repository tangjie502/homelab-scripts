#!/usr/bin/env bash
set -u

PROFILE_FILE="/etc/profile.d/proxy.sh"
APT_PROXY_FILE="/etc/apt/apt.conf.d/95proxies"
STATE_FILE="/etc/proxy_manager.conf"

print_line() {
  echo "=================================================="
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户执行此脚本。"
    exit 1
  fi
}

load_saved_proxy() {
  SAVED_PROXY_HOST=""
  SAVED_PROXY_PORT=""
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    SAVED_PROXY_HOST="${PROXY_HOST:-}"
    SAVED_PROXY_PORT="${PROXY_PORT:-}"
  fi
}

save_proxy_state() {
  local host="$1"
  local port="$2"
  cat >"$STATE_FILE" <<EOF
PROXY_HOST="${host}"
PROXY_PORT="${port}"
EOF
  chmod 600 "$STATE_FILE"
}

delete_proxy_state() {
  rm -f "$STATE_FILE"
}

show_status() {
  load_saved_proxy

  print_line
  echo "当前代理状态"
  print_line

  echo
  echo "[已保存的代理参数]"
  if [ -n "$SAVED_PROXY_HOST" ] && [ -n "$SAVED_PROXY_PORT" ]; then
    echo "代理地址: $SAVED_PROXY_HOST"
    echo "代理端口: $SAVED_PROXY_PORT"
    echo "代理URL : http://${SAVED_PROXY_HOST}:${SAVED_PROXY_PORT}"
  else
    echo "未保存代理地址和端口"
  fi

  echo
  echo "[系统代理配置文件]"
  if [ -f "$PROFILE_FILE" ]; then
    echo "已存在: $PROFILE_FILE"
    echo
    cat "$PROFILE_FILE"
  else
    echo "未配置系统代理"
  fi

  echo
  echo "[当前 shell 环境变量]"
  env | grep -i proxy || echo "当前 shell 未加载代理环境变量"

  echo
  echo "[APT 代理配置文件]"
  if [ -f "$APT_PROXY_FILE" ]; then
    echo "已存在: $APT_PROXY_FILE"
    echo
    cat "$APT_PROXY_FILE"
  else
    echo "未配置 apt 代理"
  fi

  echo
  echo "[APT 当前识别到的代理]"
  apt-config dump | grep -i proxy || echo "apt 当前未识别到代理配置"

  if [ -n "$SAVED_PROXY_HOST" ] && [ -n "$SAVED_PROXY_PORT" ]; then
    echo
    echo "[代理连通性检测]"
    if command -v nc >/dev/null 2>&1; then
      if nc -z -w 3 "$SAVED_PROXY_HOST" "$SAVED_PROXY_PORT" >/dev/null 2>&1; then
        echo "代理服务器可连接: ${SAVED_PROXY_HOST}:${SAVED_PROXY_PORT}"
      else
        echo "代理服务器不可连接: ${SAVED_PROXY_HOST}:${SAVED_PROXY_PORT}"
      fi
    else
      echo "未安装 nc，跳过连通性检测"
    fi
  fi
}

validate_ip() {
  local ip="$1"
  if echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    IFS='.' read -r o1 o2 o3 o4 <<EOF
$ip
EOF
    for octet in "$o1" "$o2" "$o3" "$o4"; do
      if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
        return 1
      fi
    done
    return 0
  fi
  return 1
}

validate_port() {
  local port="$1"
  if echo "$port" | grep -Eq '^[0-9]+$' && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
    return 0
  fi
  return 1
}

test_proxy_connectivity() {
  local host="$1"
  local port="$2"

  echo
  echo "[1/2] 检测 TCP 连通性..."
  if ! command -v nc >/dev/null 2>&1; then
    echo "未检测到 nc 命令，无法进行 TCP 连通性检测。"
    return 1
  fi

  if nc -z -w 5 "$host" "$port" >/dev/null 2>&1; then
    echo "TCP 连通正常: ${host}:${port}"
  else
    echo "TCP 连通失败: ${host}:${port}"
    return 1
  fi

  echo
  echo "[2/2] 检测 HTTP 代理可用性..."
  if curl -I -x "http://${host}:${port}" https://www.google.com --max-time 10 >/tmp/proxy_test.out 2>/tmp/proxy_test.err; then
    echo "HTTP 代理验证通过"
    return 0
  else
    echo "HTTP 代理验证失败"
    echo "错误输出:"
    sed -n '1,20p' /tmp/proxy_test.err
    return 1
  fi
}

set_system_proxy() {
  local host="$1"
  local port="$2"
  local proxy_url="http://${host}:${port}"
  local no_proxy_list="localhost,127.0.0.1,::1,${host},192.168.1.0/24"

  cat >"$PROFILE_FILE" <<EOF
export http_proxy="${proxy_url}"
export https_proxy="${proxy_url}"
export ftp_proxy="${proxy_url}"
export HTTP_PROXY="${proxy_url}"
export HTTPS_PROXY="${proxy_url}"
export FTP_PROXY="${proxy_url}"
export no_proxy="${no_proxy_list}"
export NO_PROXY="${no_proxy_list}"
EOF
  chmod +x "$PROFILE_FILE"

  export http_proxy="${proxy_url}"
  export https_proxy="${proxy_url}"
  export ftp_proxy="${proxy_url}"
  export HTTP_PROXY="${proxy_url}"
  export HTTPS_PROXY="${proxy_url}"
  export FTP_PROXY="${proxy_url}"
  export no_proxy="${no_proxy_list}"
  export NO_PROXY="${no_proxy_list}"

  echo "系统代理已设置。"
  echo "配置文件: $PROFILE_FILE"
}

set_apt_proxy() {
  local host="$1"
  local port="$2"
  local proxy_url="http://${host}:${port}"

  cat >"$APT_PROXY_FILE" <<EOF
Acquire::http::Proxy "${proxy_url}/";
Acquire::https::Proxy "${proxy_url}/";
EOF

  echo "apt 代理已设置。"
  echo "配置文件: $APT_PROXY_FILE"
}

configure_proxy() {
  local host=""
  local port=""

  echo "请输入代理地址和端口。"
  read -r -p "代理地址: " host
  read -r -p "代理端口: " port

  if ! validate_ip "$host"; then
    echo "代理地址格式不正确，仅支持 IPv4，例如 192.168.1.1"
    return 1
  fi

  if ! validate_port "$port"; then
    echo "代理端口格式不正确，必须是 1-65535 之间的数字"
    return 1
  fi

  echo
  echo "准备验证代理: http://${host}:${port}"

  if ! test_proxy_connectivity "$host" "$port"; then
    echo
    echo "代理验证未通过，未写入任何配置。"
    return 1
  fi

  echo
  echo "验证通过，开始写入配置..."
  set_system_proxy "$host" "$port"
  set_apt_proxy "$host" "$port"
  save_proxy_state "$host" "$port"

  echo
  echo "代理已成功设置。"
}

unset_system_proxy() {
  rm -f "$PROFILE_FILE"
  unset http_proxy https_proxy ftp_proxy
  unset HTTP_PROXY HTTPS_PROXY FTP_PROXY
  unset no_proxy NO_PROXY
  echo "系统代理已取消。"
}

unset_apt_proxy() {
  rm -f "$APT_PROXY_FILE"
  echo "apt 代理已取消。"
}

pause_enter() {
  echo
  read -r -p "按回车键返回菜单..." _
}

show_menu() {
  clear
  print_line
  echo "Ubuntu 代理管理脚本"
  print_line
  echo "1. 查看当前系统代理和 apt 代理状态"
  echo "2. 设置系统代理 + apt 代理"
  echo "3. 取消系统代理"
  echo "4. 取消 apt 代理"
  echo "5. 退出"
  echo
}

main() {
  require_root

  while true; do
    show_menu
    read -r -p "请输入菜单编号 [1-5]: " choice
    echo

    case "$choice" in
      1)
        show_status
        pause_enter
        ;;
      2)
        configure_proxy
        echo
        show_status
        pause_enter
        ;;
      3)
        unset_system_proxy
        echo
        show_status
        pause_enter
        ;;
      4)
        unset_apt_proxy
        echo
        show_status
        pause_enter
        ;;
      5)
        echo "已退出。"
        exit 0
        ;;
      *)
        echo "输入无效，请输入 1-5。"
        pause_enter
        ;;
    esac
  done
}

main
