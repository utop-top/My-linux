#!/bin/bash

# 定义变量
EMAIL="looksend@outlook.com"      # 用于接收证书到期提醒的邮箱
CERT_PATH="/root/Nginx/Certbot"   # 证书存储路径
WEBROOT_PATH="/var/www/certbot"   # Webroot 目录
NGINX_PORT=80                     # 临时 Nginx 监听端口
STAGING=0                         # 设为 1 使用测试环境
THRESHOLD_DAYS=30                 # 续期阈值（30 天）
NGINX_CONTAINER="nginx-host"      # 你的 Nginx 容器名称，用于重载
LOG_FILE="/var/log/certbot_manager.log"  # 日志文件路径

# 检查 Docker 是否安装
if ! [ -x "$(command -v docker)" ]; then
  echo "❌ Docker 未安装，请先安装 Docker！"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Docker 未安装" >> "$LOG_FILE"
  exit 1
fi

# 日志记录函数
function log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"
}

# 创建日志文件（如果不存在）
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"
fi

# 显示菜单
function show_menu() {
  echo ""
  echo "=== Certbot 证书管理工具 ==="
  echo "1. 查看已有证书及到期时间"
  echo "2. 删除已有证书"
  echo "3. 申请新证书"
  echo "4. 设置自动检查并续期证书（Cron 任务）"
  echo "5. 强制重新获取所有证书"
  echo "6. 退出"
  echo "===================================="
  read -p "请选择操作 (1/2/3/4/5/6): " CHOICE
}

# 查看已有证书
function list_certs() {
  echo "=== 现有域名证书 ==="
  log "INFO" "开始查看已有证书"
  EXISTING_CERTS=$(docker run --rm -v "$CERT_PATH:/etc/letsencrypt" certbot/certbot certificates | grep -E "Certificate Name|Expiry Date")
  
  if [ -z "$EXISTING_CERTS" ]; then
    echo "🔴 没有找到已存在的证书。"
    log "INFO" "没有找到已存在的证书"
  else
    echo "$EXISTING_CERTS" | while read -r LINE; do
      if [[ $LINE == "Certificate Name:"* ]]; then
        DOMAIN=$(echo "$LINE" | awk '{print $3}')
      fi
      if [[ $LINE == "Expiry Date:"* ]]; then
        EXPIRY_DATE=$(echo "$LINE" | awk '{print $3, $4, $5}')
        EXPIRY_TIMESTAMP=$(date -d "$EXPIRY_DATE" +%s)
        CURRENT_DATE=$(date +%s)
        REMAINING_DAYS=$(( (EXPIRY_TIMESTAMP - CURRENT_DATE) / 86400 ))
        echo "🔹 $DOMAIN - 到期时间: $EXPIRY_DATE ($REMAINING_DAYS 天)"
        log "INFO" "证书 $DOMAIN - 到期时间: $EXPIRY_DATE ($REMAINING_DAYS 天)"
      fi
    done
  fi
  log "INFO" "查看证书操作完成"
}

# 删除证书
function delete_cert() {
  read -p "请输入要删除的域名: " DELETE_DOMAIN
  if [ -z "$DELETE_DOMAIN" ]; then
    echo "❌ 请输入有效的域名！"
    log "ERROR" "删除证书失败：未输入域名"
  else
    echo "⚠️ 即将删除证书: $DELETE_DOMAIN"
    log "INFO" "开始删除证书: $DELETE_DOMAIN"
    docker run --rm -v "$CERT_PATH:/etc/letsencrypt" certbot/certbot delete --cert-name "$DELETE_DOMAIN"
    if [ $? -eq 0 ]; then
      echo "✅ 证书 $DELETE_DOMAIN 已删除！"
      log "INFO" "证书 $DELETE_DOMAIN 删除成功"
    else
      echo "❌ 删除证书 $DELETE_DOMAIN 失败！"
      log "ERROR" "删除证书 $DELETE_DOMAIN 失败"
    fi
  fi
}

# 创建临时 Nginx 容器
function start_temp_nginx() {
  NGINX_CONF=$(mktemp)
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;  # 通配所有域名
    root /var/www/certbot;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

  # 检查 80 端口是否被占用
  if netstat -tuln | grep ":$NGINX_PORT " > /dev/null; then
    echo "❌ 端口 $NGINX_PORT 已被占用，请释放端口或更改 NGINX_PORT 变量！"
    log "ERROR" "启动临时 Nginx 失败：端口 $NGINX_PORT 已被占用"
    rm -f "$NGINX_CONF"
    return 1
  fi

  # 创建 Webroot 目录
  mkdir -p "$WEBROOT_PATH/.well-known/acme-challenge"
  chmod -R 755 "$WEBROOT_PATH"

  # 启动临时 Nginx 容器
  echo "🚀 启动临时 Nginx 容器用于验证..."
  log "INFO" "启动临时 Nginx 容器用于验证所有域名"
  docker run -d --name temp-nginx -p "$NGINX_PORT:80" -v "$WEBROOT_PATH:/var/www/certbot" -v "$NGINX_CONF:/etc/nginx/conf.d/default.conf" nginx:latest
  sleep 2
  rm -f "$NGINX_CONF"
  return 0
}

# 清理临时 Nginx 容器
function cleanup_temp_nginx() {
  echo "🧹 清理：停止并删除临时 Nginx 容器..."
  log "INFO" "清理临时 Nginx 容器"
  docker stop temp-nginx >/dev/null 2>&1
  docker rm temp-nginx >/dev/null 2>&1
}

# 申请新证书
function request_cert() {
  read -p "请输入你要获取证书的域名（例如 example.com）: " DOMAIN

  if [ -z "$DOMAIN" ]; then
    echo "❌ 请输入有效的域名！"
    log "ERROR" "申请证书失败：未输入域名"
    return
  fi

  echo "⚡ 你输入的域名是：$DOMAIN"
  log "INFO" "用户输入域名: $DOMAIN"
  read -p "确认无误？(y/n): " CONFIRM
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "❌ 已取消操作！"
    log "INFO" "用户取消申请证书操作"
    return
  fi

  # 启动临时 Nginx
  start_temp_nginx
  if [ $? -ne 0 ]; then
    return
  fi

  # 设置 staging 参数
  STAGING_FLAG=""
  if [ "$STAGING" -eq 1 ]; then
    STAGING_FLAG="--staging"
  fi

  # 运行 Certbot 获取证书
  echo "🔹 正在为 $DOMAIN 获取证书..."
  log "INFO" "开始为 $DOMAIN 获取证书"
  docker run --rm -v "$CERT_PATH:/etc/letsencrypt" -v "$WEBROOT_PATH:/var/www/certbot" certbot/certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email $STAGING_FLAG

  # 检查证书是否生成成功
  if [ $? -eq 0 ]; then
    echo "✅ 证书获取成功！存储在 $CERT_PATH/live/$DOMAIN/"
    log "INFO" "证书获取成功，路径: $CERT_PATH/live/$DOMAIN/"
  else
    echo "❌ 证书获取失败，请检查日志或网络配置！"
    log "ERROR" "证书获取失败: $DOMAIN"
    docker logs temp-nginx >> "$LOG_FILE"
  fi

  # 清理临时 Nginx
  cleanup_temp_nginx
  echo "🎉 证书申请操作完成！"
  log "INFO" "证书申请操作完成"
}

# 强制重新获取所有证书
function force_renew_all() {
  # 获取所有证书的域名
  DOMAINS=$(docker run --rm -v "$CERT_PATH:/etc/letsencrypt" certbot/certbot certificates | grep "Certificate Name" | awk '{print $3}')
  if [ -z "$DOMAINS" ]; then
    echo "🔴 没有找到需要重新获取的证书！"
    log "INFO" "没有找到需要重新获取的证书"
    return
  fi

  echo "🔄 正在强制重新获取所有证书..."
  log "INFO" "开始强制重新获取所有证书"
  
  # 启动临时 Nginx（只启动一次）
  start_temp_nginx
  if [ $? -ne 0 ]; then
    return
  fi

  # 设置 staging 参数
  STAGING_FLAG=""
  if [ "$STAGING" -eq 1 ]; then
    STAGING_FLAG="--staging"
  fi

  # 逐个重新获取证书
  for DOMAIN in $DOMAINS; do
    echo "🔹 正在为 $DOMAIN 重新获取证书..."
    log "INFO" "开始为 $DOMAIN 重新获取证书"
    docker run --rm -v "$CERT_PATH:/etc/letsencrypt" -v "$WEBROOT_PATH:/var/www/certbot" certbot/certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --force-renewal $STAGING_FLAG

    if [ $? -eq 0 ]; then
      echo "✅ $DOMAIN 证书重新获取成功！"
      log "INFO" "证书重新获取成功: $DOMAIN"
    else
      echo "❌ $DOMAIN 证书重新获取失败，请检查日志！"
      log "ERROR" "证书重新获取失败: $DOMAIN"
      docker logs temp-nginx >> "$LOG_FILE"
    fi
  done

  # 所有证书处理完成后清理临时 Nginx
  cleanup_temp_nginx

  # 检查是否所有证书都处理完成
  if docker ps -q -f name="$NGINX_CONTAINER" > /dev/null; then
    echo "🔧 重载 Nginx 容器 $NGINX_CONTAINER..."
    log "INFO" "重载 Nginx 容器 $NGINX_CONTAINER"
    docker exec "$NGINX_CONTAINER" nginx -s reload
  else
    echo "⚠️ Nginx 容器 $NGINX_CONTAINER 未运行，跳过重载。"
    log "WARN" "Nginx 容器 $NGINX_CONTAINER 未运行，跳过重载"
  fi

  echo "🎉 所有证书强制重新获取解决完成！"
  log "INFO" "所有证书强制重新获取操作完成"
}

# 设置自动检查并续期证书（Cron 任务）
function setup_auto_renew() {
  CRON_SCRIPT="/usr/local/bin/certbot_renew_check.sh"
  
  # 创建检查并重新获取证书的脚本
  cat > "$CRON_SCRIPT" <<EOF
#!/bin/bash
CERT_PATH="$CERT_PATH"
WEBROOT_PATH="$WEBROOT_PATH"
NGINX_PORT=$NGINX_PORT
NGINX_CONTAINER="$NGINX_CONTAINER"
LOG_FILE="$LOG_FILE"
EMAIL="$EMAIL"
STAGING=$STAGING
THRESHOLD_DAYS=$THRESHOLD_DAYS

# 日志记录函数
log() {
  echo "\$(date '+%Y-%m-%d %H:%M:%S') [\$1] \$2" >> "\$LOG_FILE"
}

# 获取所有证书的域名和到期时间
CERT_INFO=\$(docker run --rm -v "\$CERT_PATH:/etc/letsencrypt" certbot/certbot certificates | grep -E "Certificate Name|Expiry Date")

if [ -z "\$CERT_INFO" ]; then
  log "INFO" "没有找到证书，跳过检查和续期"
  exit 0
fi

# 解析证书信息，检查是否需要续期
DOMAINS_TO_RENEW=""
echo "\$CERT_INFO" | while read -r LINE; do
  if [[ \$LINE == "Certificate Name:"* ]]; then
    DOMAIN=\$(echo "\$LINE" | awk '{print \$3}')
  fi
  if [[ \$LINE == "Expiry Date:"* ]]; then
    EXPIRY_DATE=\$(echo "\$LINE" | awk '{print \$3, \$4, \$5}')
    EXPIRY_TIMESTAMP=\$(date -d "\$EXPIRY_DATE" +%s)
    CURRENT_TIMESTAMP=\$(date +%s)
    REMAINING_DAYS=\$(( (EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP) / 86400 ))
    log "INFO" "检查证书 \$DOMAIN，到期时间: \$EXPIRY_DATE，剩余: \$REMAINING_DAYS 天"
    if [ "\$REMAINING_DAYS" -lt "\$THRESHOLD_DAYS" ]; then
      DOMAINS_TO_RENEW="\$DOMAINS_TO_RENEW \$DOMAIN"
    fi
  fi
done

# 如果没有需要续期的证书，退出
if [ -z "\$DOMAINS_TO_RENEW" ]; then
  log "INFO" "所有证书有效期均大于 \$THRESHOLD_DAYS 天，无需续期"
  exit 0
fi

# 创建临时 Nginx 配置文件
NGINX_CONF=\$(mktemp)
cat > "\$NGINX_CONF" <<NGINX_EOF
server {
    listen 80;
    server_name _;
    root /var/www/certbot;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }
}
NGINX_EOF

# 检查 80 端口是否可用
if netstat -tuln | grep ":$NGINX_PORT " > /dev/null; then
  log "ERROR" "端口 \$NGINX_PORT 已被占用，跳过续期"
  rm -f "\$NGINX_CONF"
  exit 1
fi

# 创建 Webroot 目录
mkdir -p "\$WEBROOT_PATH/.well-known/acme-challenge"
chmod -R 755 "\$WEBROOT_PATH"

# 启动临时 Nginx
log "INFO" "启动临时 Nginx 用于验证"
docker run -d --name temp-nginx -p "\$NGINX_PORT:80" -v "\$WEBROOT_PATH:/var/www/certbot" -v "\$NGINX_CONF:/etc/nginx/conf.d/default.conf" nginx:latest
sleep 2

# 设置 staging 参数
STAGING_FLAG=""
if [ "\$STAGING" -eq 1 ]; then
  STAGING_FLAG="--staging"
fi

# 仅对需要续期的证书执行续期
for DOMAIN in \$DOMAINS_TO_RENEW; do
  log "INFO" "证书 \$DOMAIN 剩余有效期小于 \$THRESHOLD_DAYS 天，开始续期"
  docker run --rm -v "\$CERT_PATH:/etc/letsencrypt" -v "\$WEBROOT_PATH:/var/www/certbot" certbot/certbot certonly --webroot -w /var/www/certbot -d "\$DOMAIN" --email "\$EMAIL" --agree-tos --no-eff-email --force-renewal \$STAGING_FLAG
  if [ \$? -eq 0 ]; then
    log "INFO" "成功续期证书: \$DOMAIN"
  else
    log "ERROR" "续期证书失败: \$DOMAIN"
  fi
done

# 清理临时 Nginx
log "INFO" "清理临时 Nginx 容器"
docker stop temp-nginx >/dev/null 2>&1
docker rm temp-nginx >/dev/null 2>&1
rm -f "\$NGINX_CONF"

# 重载 Nginx
if docker ps -q -f name="\$NGINX_CONTAINER" > /dev/null; then
  log "INFO" "重载 Nginx 容器 \$NGINX_CONTAINER"
  docker exec "\$NGINX_CONTAINER" nginx -s reload
else
  log "WARN" "Nginx 容器 \$NGINX_CONTAINER 未运行，跳过重载"
fi

log "INFO" "证书续期操作完成"
EOF

  chmod +x "$CRON_SCRIPT"
  log "INFO" "创建或更新自动检查并续期证书脚本: $CRON_SCRIPT"

  # 清理旧的 Cron 任务
  if crontab -l 2>/dev/null | grep -F "certbot_renew.sh" > /dev/null; then
    echo "🧹 检测到旧的 certbot_renew.sh 任务，正在清理..."
    log "INFO" "清理旧的 certbot_renew.sh Cron 任务"
    crontab -l | grep -v "certbot_renew.sh" | crontab -
  fi
  if crontab -l 2>/dev/null | grep -F "certbot_force_renew.sh" > /dev/null; then
    echo "🧹 检测到旧的 certbot_force_renew.sh 任务，正在清理..."
    log "INFO" "清理旧的 certbot_force_renew.sh Cron 任务"
    crontab -l | grep -v "certbot_force_renew.sh" | crontab -
  fi

  # 设置新的 Cron 任务
  CRON_JOB="0 */12 * * * $CRON_SCRIPT >> $LOG_FILE 2>&1"
  if ! crontab -l 2>/dev/null | grep -F "$CRON_SCRIPT" > /dev/null; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "✅ 已设置自动检查并续期证书任务，每 12 小时执行一次！"
    log "INFO" "已设置自动检查并续期证书任务，每 12 小时执行一次"
  else
    echo "ℹ️ 自动检查并续期证书任务已存在，无需重复设置。"
    log "INFO" "自动检查并续期证书任务已存在"
  fi

  # 验证 Cron 服务
  if ! systemctl is-active cron > /dev/null 2>&1; then
    echo "⚠️ Cron 服务未运行，尝试启动..."
    log "WARN" "Cron 服务未运行，尝试启动"
    sudo systemctl start cron
    sudo systemctl enable cron
    log "INFO" "Cron 服务已启动并设置为开机自启"
  fi
}

# 主循环
while true; do
  show_menu
  log "INFO" "用户选择操作: $CHOICE"
  case $CHOICE in
    1) list_certs ;;
    2) delete_cert ;;
    3) request_cert ;;
    4) setup_auto_renew ;;
    5) force_renew_all ;;
    6) echo "🚪 退出脚本"; log "INFO" "用户退出脚本"; exit 0 ;;
    *) echo "❌ 请输入有效选项 (1/2/3/4/5/6)！"; log "ERROR" "无效选项: $CHOICE" ;;
  esac
done