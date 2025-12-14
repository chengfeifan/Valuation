#!/usr/bin/env bash
set -euo pipefail

# =========================
# 一键反向代理 + SSL 安装脚本
# 适用：Debian/Ubuntu (Vultr)
# 功能：
# - 安装 Nginx/Certbot
# - 反向代理到 Cloud Run
# - 有域名：自动签发 Let’s Encrypt
# - 无域名：自动生成自签名证书
# - 支持 WebSocket/SSE，合理超时
# =========================

# 默认上游（你的 Cloud Run 地址）
DEFAULT_UPSTREAM="https://service-297902607952.us-west1.run.app/"

# ========== 参数 ==========
DOMAIN="${DOMAIN:-}"       # 形如: dyeing.example.com（不填则走自签名）
EMAIL="${EMAIL:-}"         # 形如: admin@example.com（Let’s Encrypt 需要；无域名时可不填）
UPSTREAM="${UPSTREAM:-$DEFAULT_UPSTREAM}"  # 可自定义上游
ENABLE_UFW="${ENABLE_UFW:-true}"           # 是否自动放行 UFW 端口: true/false

# 也支持命令行传参（优先级高于环境变量）
# 用法示例：
#   DOMAIN=dyeing.example.com EMAIL=admin@example.com bash install_proxy.sh
#   bash install_proxy.sh --domain dyeing.example.com --email admin@example.com --upstream https://xxx.run.app/
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --upstream) UPSTREAM="$2"; shift 2 ;;
    --enable-ufw) ENABLE_UFW="$2"; shift 2 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

echo "==> 配置参数："
echo "    DOMAIN  = ${DOMAIN:-<无域名，自签名SSL>}"
echo "    EMAIL   = ${EMAIL:-<未设置>}"
echo "    UPSTREAM= ${UPSTREAM}"
echo "    UFW     = ${ENABLE_UFW}"

# ========== 基础校验 ==========
if ! command -v apt >/dev/null 2>&1; then
  echo "本脚本仅支持 Debian/Ubuntu（需要 apt）。" >&2
  exit 1
fi

if [[ -n "${DOMAIN}" && -z "${EMAIL}" ]]; then
  echo "提示：使用 Let’s Encrypt 建议同时提供 EMAIL（--email）。"
fi

# 解析上游主机名（用于 Host 头转发给 Cloud Run）
UPSTREAM_HOST="$(echo "${UPSTREAM}" | awk -F/ '{print $3}')"
if [[ -z "${UPSTREAM_HOST}" ]]; then
  echo "无法解析 UPSTREAM 主机名，请检查 UPSTREAM=${UPSTREAM}" >&2
  exit 1
fi

# ========== 安装依赖 ==========
echo "==> 更新并安装 Nginx/Certbot..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y nginx curl ca-certificates
# certbot 仅在有域名时需要，但提前装上也无妨
apt install -y certbot python3-certbot-nginx || true

# ========== UFW 放行 ==========
if command -v ufw >/dev/null 2>&1; then
  if [[ "${ENABLE_UFW}" == "true" ]]; then
    echo "==> UFW 放行 Nginx Full (80/443)..."
    ufw allow 'Nginx Full' || true
    ufw delete allow 'Nginx HTTP' 2>/dev/null || true
  fi
fi

# ========== 写 Nginx 配置（80端口） ==========
SITE_NAME="reverse_proxy"
CONF_PATH="/etc/nginx/sites-available/${SITE_NAME}"
ENABLED_PATH="/etc/nginx/sites-enabled/${SITE_NAME}"

echo "==> 生成 Nginx 配置（80 端口）..."
cat > "${CONF_PATH}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN:-_};

    # 可在 HTTP 下先跑通，后续由 certbot 自动接管为 HTTPS
    location / {
        proxy_http_version 1.1;
        proxy_set_header Host ${UPSTREAM_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket/SSE
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_ssl_server_name on;
        proxy_pass ${UPSTREAM};

        proxy_redirect off;
        proxy_buffering off;

        # 超时（Cloud Run 冷启动/长轮询）
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # 可选：健康检查
    location = /healthz {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}
EOF

ln -sf "${CONF_PATH}" "${ENABLED_PATH}"
nginx -t
systemctl enable nginx
systemctl restart nginx

# ========== SSL 配置 ==========
if [[ -n "${DOMAIN}" ]]; then
  echo "==> 检测到域名，尝试使用 Let’s Encrypt 自动签发..."
  # 确保域名已解析到本机 IP，否则验证会失败
  # --redirect: 自动将 HTTP 重定向到 HTTPS
  CERTBOT_ARGS=(--nginx -d "${DOMAIN}" --redirect --non-interactive --agree-tos)
  if [[ -n "${EMAIL}" ]]; then
    CERTBOT_ARGS+=(-m "${EMAIL}")
  else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
  fi

  if certbot "${CERTBOT_ARGS[@]}"; then
    echo "==> Let’s Encrypt 证书签发成功。"
  else
    echo "!! Let’s Encrypt 签发失败，继续使用 HTTP（80）服务。"
    echo "   你也可以稍后在 DNS 正确指向后运行："
    echo "   certbot --nginx -d ${DOMAIN} --redirect -m you@example.com --agree-tos --non-interactive"
  fi
else
  echo "==> 未提供域名，生成自签名证书（便于 HTTPS 访问，浏览器会提示不受信任）..."
  SSL_DIR="/etc/nginx/selfsigned"
  mkdir -p "${SSL_DIR}"
  if [[ ! -f "${SSL_DIR}/selfsigned.key" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "${SSL_DIR}/selfsigned.key" \
      -out "${SSL_DIR}/selfsigned.crt" \
      -subj "/CN=$(hostname -f)"
  fi

  # 写 443 配置（自签名）
  CONF_SSL_PATH="/etc/nginx/sites-available/${SITE_NAME}_ssl"
  ENABLED_SSL_PATH="/etc/nginx/sites-enabled/${SITE_NAME}_ssl"

  cat > "${CONF_SSL_PATH}" <<EOF
server {
    listen 443 ssl http2;
    server_name _;

    ssl_certificate     ${SSL_DIR}/selfsigned.crt;
    ssl_certificate_key ${SSL_DIR}/selfsigned.key;

    # 基本安全加固（简化版）
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host ${UPSTREAM_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_ssl_server_name on;
        proxy_pass ${UPSTREAM};

        proxy_redirect off;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location = /healthz {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}

# 将 80 强制跳转到 443（无域名场景下按需开启）
server {
    listen 80;
    server_name _;
    return 301 https://\$host\$request_uri;
}
EOF

  ln -sf "${CONF_SSL_PATH}" "${ENABLED_SSL_PATH}"
  nginx -t
  systemctl reload nginx
fi

# ========== 完成信息 ==========
IP="$(curl -s https://api.ipify.org || echo "<你的服务器IP>")"
echo
echo "================ 完成 ================"
echo "Nginx 已安装并配置完成。"
echo "上游（Cloud Run）：${UPSTREAM}"
if [[ -n "${DOMAIN}" ]]; then
  echo "访问（推荐）：https://${DOMAIN}/"
  echo "如证书签发失败，可先访问：http://${DOMAIN}/"
else
  echo "未配置域名："
  echo "  - HTTP:  http://${IP}/"
  echo "  - HTTPS: https://${IP}/  （自签名证书，浏览器会提示不受信任）"
fi
echo "健康检查：/healthz"
echo "配置文件：${CONF_PATH}"
echo "======================================"
