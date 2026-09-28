#!/usr/bin/env bash
# Install: bash install.sh
# Show nodes after the server IP changes: bash /root/hysteria2/install.sh show [current-public-ip]
set -euo pipefail
umask 077

DIR=/root/hysteria2
CONFIG=$DIR/config.json
CERT=$DIR/server.crt
KEY=$DIR/server.key
BIN=$DIR/sing-box
SCRIPT=$DIR/install.sh
UNIT=$DIR/hysteria2-singbox.service
SERVICE=hysteria2-singbox.service
SNI=hy2.invalid
INSTALL_STAGE=

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

architecture() {
  case "$1" in
    x86_64|amd64) echo amd64 ;;
    i386|i486|i586|i686) echo 386 ;;
    aarch64|arm64) echo arm64 ;;
    armv8l|armv7l|armv7) echo armv7 ;;
    armv6l|armv6) echo armv6 ;;
    armv5*) echo armv5 ;;
    riscv64|s390x|ppc64le) echo "$1" ;;
    loongarch64|loong64) echo loong64 ;;
    mipsel|mipsle) echo mipsle ;;
    mips64el|mips64le) echo mips64le ;;
    *) return 1 ;;
  esac
}

need_root() {
  [[ $EUID -eq 0 ]] || die '请以 root 运行。'
}

need_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] ||
    die '此脚本需要以 systemd 管理服务的 Linux 系统。'
}

ensure_tools() {
  local tool package
  local missing=() packages=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  ((${#missing[@]})) || return 0

  for tool in "${missing[@]}"; do
    case "$tool" in
      sha256sum) package=coreutils ;;
      *) package=$tool ;;
    esac
    packages+=("$package")
    [[ $tool != curl ]] || packages+=(ca-certificates)
  done
  note "安装缺少的工具：${packages[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${packages[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --needed --noconfirm "${packages[@]}"
  else
    die '缺少安装工具，且未找到支持的包管理器。'
  fi
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "仍缺少工具：$tool"
  done
}

valid_ip() {
  local ip=$1 part count=0 rest
  [[ -n $ip && ${#ip} -le 45 && $ip =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  if [[ $ip == *:* ]]; then
    [[ $ip != *.* && $ip != *:::* ]] || return 1
    if [[ $ip == *::* ]]; then
      rest=${ip#*::}
      [[ $rest != *::* ]] || return 1
    else
      [[ $ip != :* && $ip != *: ]] || return 1
    fi
    rest=${ip//:/ }
    for part in $rest; do
      [[ $part =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      ((count += 1))
    done
    if [[ $ip == *::* ]]; then
      ((count > 0 && count < 8)) || return 1
    else
      ((count == 8)) || return 1
    fi
  else
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local octets=()
    IFS=. read -r -a octets <<<"$ip"
    for part in "${octets[@]}"; do ((10#$part <= 255)) || return 1; done
  fi
}

detect_ip() {
  local ip
  ip=$(curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 8 \
    https://api.ip.sb/ip 2>/dev/null) || ip=
  if valid_ip "$ip"; then printf '%s\n' "$ip"; return 0; fi
  ip=$(curl -6 -fsS --noproxy '*' --connect-timeout 5 --max-time 8 \
    https://api.ip.sb/ip 2>/dev/null) || ip=
  if valid_ip "$ip"; then printf '%s\n' "$ip"; return 0; fi
  return 1
}

current_ip() {
  local ip=${1:-}
  if [[ -z $ip ]]; then
    ip=$(detect_ip) || ip=
    if [[ -n $ip ]]; then
      note "当前公网 IP：$ip" >&2
    else
      read -r -p '无法从 ip.sb 获取公网 IP，请输入当前公网 IP：' ip </dev/tty ||
        die '无法获取公网 IP，且没有可用终端输入。可运行 show 并附上当前 IP。'
    fi
  fi
  valid_ip "$ip" || die "无效的 IP 地址：$ip"
  printf '%s\n' "$ip"
}

prompt_port() {
  local port
  while true; do
    read -r -p 'Hysteria2 UDP 端口 [443]：' port </dev/tty || die '需要交互式终端输入端口。'
    port=${port:-443}
    if [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)); then
      printf '%s\n' "$((10#$port))"
      return
    fi
    note '端口必须在 1–65535 之间。' >&2
  done
}

valid_password() {
  [[ ${#1} -ge 8 && ${#1} -le 128 && $1 =~ ^[A-Za-z0-9._~-]+$ ]]
}

prompt_password() {
  local password confirm
  while true; do
    read -r -s -p '连接密码（留空随机生成；自定义需 8–128 位字母、数字或 -._~）：' password </dev/tty ||
      die '需要交互式终端输入密码。'
    printf '\n' >/dev/tty
    if [[ -z $password ]]; then openssl rand -hex 24; return; fi
    if ! valid_password "$password"; then
      note '密码格式无效，请重新输入。' >&2
      continue
    fi
    read -r -s -p '再次输入密码：' confirm </dev/tty || die '需要确认密码。'
    printf '\n' >/dev/tty
    if [[ $password == "$confirm" ]]; then printf '%s\n' "$password"; return; fi
    note '两次输入不一致，请重新输入。' >&2
  done
}

show() {
  [[ -f $CONFIG && -f $CERT ]] || die "找不到已安装的配置或证书：$DIR"
  ensure_tools openssl
  local ip=${1:-} config port password fingerprint pubkey_pin host uri_pin
  if [[ -z $ip ]]; then ensure_tools curl; fi
  ip=$(current_ip "$ip")
  config=$(<"$CONFIG")
  local port_pattern='"listen_port"[[:space:]]*:[[:space:]]*([0-9]+)'
  local password_pattern='"password"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._~-]{8,128})"'
  [[ $config =~ $port_pattern ]] || die '无法从服务端配置读取端口。'
  port=${BASH_REMATCH[1]}
  [[ $config =~ $password_pattern ]] || die '无法从服务端配置读取密码。'
  password=${BASH_REMATCH[1]}
  fingerprint=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256)
  fingerprint=${fingerprint#*=}
  pubkey_pin=$(openssl x509 -in "$CERT" -pubkey -noout | \
    openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64 -A)
  [[ $fingerprint =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ && -n $pubkey_pin ]] ||
    die '证书指纹计算失败。'
  host=$ip
  [[ $ip != *:* ]] || host="[$ip]"
  uri_pin=${fingerprint//:/%3A}

  printf '\nv2rayN / v2rayNG 分享链接：\n'
  printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1&pinSHA256=%s#HY2\n' \
    "$password" "$host" "$port" "$SNI" "$uri_pin"
  printf '\nMihomo 单节点 YAML：\n'
  cat <<EOF
proxies:
  - name: "HY2"
    type: hysteria2
    server: "$ip"
    port: $port
    password: "$password"
    sni: "$SNI"
    fingerprint: "$fingerprint"
EOF
  printf '\nsing-box 单节点出站 JSON（客户端 1.13+）：\n'
  cat <<EOF
{
  "type": "hysteria2",
  "tag": "HY2",
  "server": "$ip",
  "server_port": $port,
  "password": "$password",
  "tls": {
    "enabled": true,
    "server_name": "$SNI",
    "certificate_public_key_sha256": ["$pubkey_pin"]
  }
}
EOF
  printf '\nIP 变化后运行：bash %s show\n' "$SCRIPT"
}

write_unit() {
  if [[ ( -e /etc/systemd/system/$SERVICE || -L /etc/systemd/system/$SERVICE ) &&
        ! /etc/systemd/system/$SERVICE -ef $UNIT ]]; then
    die "系统中已有其他 $SERVICE，未覆盖。"
  fi
  cat >"$UNIT" <<EOF
[Unit]
Description=Hysteria2 server (sing-box)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$DIR
ExecStart=$BIN run -c $CONFIG
Restart=on-failure
RestartSec=3
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chmod 600 "$UNIT"
  systemctl daemon-reload
  systemctl enable --now "$UNIT"
  sleep 1
  systemctl is-enabled --quiet "$SERVICE" || die 'systemd 服务未设置开机启动。'
  systemctl is-active --quiet "$SERVICE" || die "服务启动失败，请查看：journalctl -u $SERVICE -e"
}

open_firewall() {
  local port=$1 status
  if command -v ufw >/dev/null 2>&1; then
    status=$(LC_ALL=C ufw status 2>/dev/null) || status=
    if [[ $status == *'Status: active'* ]]; then
      ufw allow "$port/udp" || note "警告：UFW 未能开放 UDP $port。" >&2
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if ! firewall-cmd --query-port="$port/udp" >/dev/null 2>&1; then
      if firewall-cmd --permanent --add-port="$port/udp" && firewall-cmd --reload; then
        note "firewalld 已开放 UDP $port。"
      else
        note "警告：firewalld 未能开放 UDP $port。" >&2
      fi
    fi
  fi
}

release_asset() {
  local arch=$1 metadata compact version archive marker asset_data digest
  local tag_pattern='"tag_name":"v([0-9]+\.[0-9]+\.[0-9]+)"'
  local digest_pattern='"digest":"sha256:([0-9a-f]{64})"'
  metadata=$(curl -fsSL --retry 3 --connect-timeout 15 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: hysteria2-singbox-installer' \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest) || die '无法读取 sing-box 官方发布信息。'
  compact=${metadata//[[:space:]]/}
  [[ $compact =~ $tag_pattern ]] || die '官方最新稳定版版本号无效。'
  version=${BASH_REMATCH[1]}
  local major minor patch
  IFS=. read -r major minor patch <<<"$version"
  ((major > 1 || (major == 1 && minor >= 13))) || die 'sing-box 最新稳定版低于 1.13。'
  archive="sing-box-$version-linux-$arch.tar.gz"
  marker="\"name\":\"$archive\""
  [[ $compact == *"$marker"* ]] || die "此版本没有适合本机架构的发布包：$archive"
  asset_data=${compact#*"$marker"}
  [[ $asset_data == *'"download_count"'* ]] || die '官方发布信息中缺少发布包边界。'
  asset_data=${asset_data%%\"download_count\"*}
  [[ $asset_data =~ $digest_pattern ]] || die '官方发布包缺少 SHA-256 校验值。'
  digest=${BASH_REMATCH[1]}
  printf '%s %s %s\n' "$version" "$archive" "$digest"
}

install_script() {
  if [[ ! $0 -ef $SCRIPT ]]; then cp "$0" "$SCRIPT"; fi
  chmod 700 "$SCRIPT"
}

install_new() {
  local arch port ip release_info version archive digest url listen password
  arch=$(architecture "$(uname -m)") || die "不支持的架构：$(uname -m)"
  ensure_tools curl openssl tar sha256sum
  port=$(prompt_port)
  password=$(prompt_password)
  ip=$(current_ip)
  mkdir -p "$DIR"
  chmod 700 "$DIR"
  INSTALL_STAGE=$(mktemp -d "$DIR/.install.XXXXXX")
  trap '[[ -z $INSTALL_STAGE ]] || rm -rf -- "$INSTALL_STAGE"' EXIT

  note "下载 sing-box 最新稳定版（linux/$arch）…"
  release_info=$(release_asset "$arch") || die '无法确定可信的 sing-box 发布包。'
  read -r version archive digest <<<"$release_info"
  url="https://github.com/SagerNet/sing-box/releases/download/v$version/$archive"
  curl -fL --retry 3 --connect-timeout 15 "$url" -o "$INSTALL_STAGE/$archive"
  printf '%s  %s\n' "$digest" "$INSTALL_STAGE/$archive" | sha256sum -c - >/dev/null ||
    die 'sing-box 下载包 SHA-256 校验失败。'
  tar -xOzf "$INSTALL_STAGE/$archive" "sing-box-$version-linux-$arch/sing-box" >"$INSTALL_STAGE/sing-box"
  chmod 700 "$INSTALL_STAGE/sing-box"
  "$INSTALL_STAGE/sing-box" version >/dev/null || die 'sing-box 二进制无法运行。'

  cat >"$INSTALL_STAGE/openssl.cnf" <<EOF
[req]
distinguished_name = subject
prompt = no
x509_extensions = server_cert
[subject]
CN = $SNI
[server_cert]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:$SNI
EOF
  openssl ecparam -genkey -name prime256v1 -noout -out "$INSTALL_STAGE/server.key"
  openssl req -new -x509 -sha256 -days 3650 -key "$INSTALL_STAGE/server.key" \
    -out "$INSTALL_STAGE/server.crt" -config "$INSTALL_STAGE/openssl.cnf" -extensions server_cert
  if [[ -s /proc/net/if_inet6 ]]; then listen='::'; else listen='0.0.0.0'; fi
  cat >"$INSTALL_STAGE/config.json" <<EOF
{
  "inbounds": [{
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": "$listen",
    "listen_port": $port,
    "users": [{"name": "default", "password": "$password"}],
    "tls": {
      "enabled": true,
      "certificate_path": "$CERT",
      "key_path": "$KEY"
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
  mv "$INSTALL_STAGE/sing-box" "$BIN"
  mv "$INSTALL_STAGE/server.crt" "$CERT"
  mv "$INSTALL_STAGE/server.key" "$KEY"
  mv "$INSTALL_STAGE/config.json" "$CONFIG"
  chmod 700 "$BIN"
  chmod 600 "$CONFIG" "$CERT" "$KEY"
  "$BIN" check -c "$CONFIG" || die 'sing-box 配置检查失败。'
  install_script
  write_unit
  open_firewall "$port"
  note "安装成功；服务已启动并设置开机自启。请同时检查云平台安全组是否开放 UDP $port。"
  show "$ip"
}

main() {
  [[ $(uname -s) == Linux ]] || die '仅支持 Linux。'
  need_root
  case ${1:-install} in
    show)
      [[ $# -le 2 ]] || die '用法：install.sh show [当前公网 IP]'
      show "${2:-}"
      ;;
    install)
      [[ $# -le 1 ]] || die '用法：bash install.sh'
      [[ -f $0 ]] || die '请先将脚本保存为文件，再运行 bash install.sh。'
      need_systemd
      if [[ -f $CONFIG && -f $CERT && -f $KEY && -x $BIN ]]; then
        note '检测到已有安装，保留现有密码和证书。'
        "$BIN" check -c "$CONFIG" || die '现有配置无效。'
        install_script
        write_unit
        show
      elif [[ -e $CONFIG || -e $CERT || -e $KEY || -e $BIN ]]; then
        die "$DIR 中存在不完整的安装；请检查该目录后重试。"
      else
        install_new
      fi
      ;;
    *) die '用法：bash install.sh [install|show [当前公网 IP]]' ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
