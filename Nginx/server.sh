#!/bin/bash

# 定义配置文件路径
CONFIG_FILE="/root/Nginx/config/other.conf"
# 定义容器名称
CONTAINER_NAME="nginx-host"

# 定义颜色代码
RED='\033[0;31m'
NC='\033[0m' # No Color

# 检查文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误：配置文件 $CONFIG_FILE 不存在"
    exit 1
fi

# 检查文件是否可写
if [ ! -w "$CONFIG_FILE" ]; then
    echo "错误：没有权限写入 $CONFIG_FILE，请检查权限"
    exit 1
fi

# 主循环
while true; do
    echo "请选择操作："
    echo "1. 添加 server 块"
    echo "2. 删除 server 块"
    echo "3. 查看 server 块代理端口"
    echo "4. 退出"
    read -p "请输入选项 (1-4): " CHOICE

    case $CHOICE in
        1)
            # 添加 server 块
            read -p "请输入服务域名（例如 example.com）: " DOMAIN
            read -p "请输入代理的本机端口（例如 8080）: " PORT

            # 验证输入
            if [ -z "$DOMAIN" ] || [ -z "$PORT" ]; then
                echo "错误：域名和端口不能为空"
                continue
            fi

            # 检查端口是否为数字
            if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
                echo "错误：端口必须是数字"
                continue
            fi

            # 定义 server 块内容
            SERVER_BLOCK="
server {
    include ssl.conf;
    server_name $DOMAIN;
    server_tokens off;

    ssl_certificate /etc/nginx/ssl/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/live/$DOMAIN/privkey.pem;
    charset utf-8;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        include proxy.conf;
    }
}
"

            # 将 server 块追加到配置文件
            echo "$SERVER_BLOCK" >> "$CONFIG_FILE"

            if [ $? -eq 0 ]; then
                echo "成功添加 server 配置到 $CONFIG_FILE"
                echo "添加的配置如下："
                echo "$SERVER_BLOCK"
                echo "请在完成后执行以下命令重载 Nginx 配置："
                echo "docker exec $CONTAINER_NAME nginx -s reload"
            else
                echo "错误：写入配置文件失败"
            fi
            ;;
        
        2)
            # 删除 server 块
            # 提取所有 server_name
            SERVER_NAMES=($(grep -oP 'server_name\s+\K[^;]+' "$CONFIG_FILE"))

            if [ ${#SERVER_NAMES[@]} -eq 0 ]; then
                echo "配置文件中没有找到任何 server 块"
                continue
            fi

            # 列出所有 server_name
            echo "当前存在的 server 块域名："
            for i in "${!SERVER_NAMES[@]}"; do
                echo "$((i+1)). ${SERVER_NAMES[$i]}"
            done

            # 提示选择要删除的域名
            read -p "请输入要删除的域名编号 (1-${#SERVER_NAMES[@]}): " SELECTED

            # 验证输入
            if ! [[ "$SELECTED" =~ ^[0-9]+$ ]] || [ "$SELECTED" -lt 1 ] || [ "$SELECTED" -gt ${#SERVER_NAMES[@]} ]; then
                echo "错误：请选择有效的编号 (1-${#SERVER_NAMES[@]})"
                continue
            fi

            # 获取选中的域名
            DOMAIN=${SERVER_NAMES[$((SELECTED-1))]}

            # 显示确认提示（红色警告）
            echo -e "${RED}警告：您即将删除域名 $DOMAIN 的 server 块，此操作不可逆！${NC}"
            read -p "确认删除吗？(y/N): " CONFIRM

            # 检查确认输入
            if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
                echo "已取消删除操作"
                continue
            fi

            # 创建临时文件
            TEMP_FILE=$(mktemp)

            # 使用 awk 精确删除目标 server 块
            awk -v domain="$DOMAIN" '
            BEGIN { level = 0; skip = 0; buffer = "" }
            {
                if ($0 ~ /^server {/) {
                    level++
                    if (buffer != "") { print buffer; buffer = "" }
                    buffer = $0
                } else if ($0 ~ /^}/ && level > 0) {
                    buffer = buffer "\n" $0
                    level--
                    if (level == 0) {
                        if (skip) { buffer = "" }
                        else { print buffer }
                        buffer = ""
                        skip = 0
                    }
                } else if (level > 0) {
                    buffer = buffer "\n" $0
                    if ($0 ~ "server_name " domain ";") { skip = 1 }
                } else {
                    print $0
                }
            }
            END { if (buffer != "") print buffer }
            ' "$CONFIG_FILE" > "$TEMP_FILE"

            # 替换原文件
            mv "$TEMP_FILE" "$CONFIG_FILE"
            
            if [ $? -eq 0 ]; then
                echo "成功删除域名 $DOMAIN 的 server 块"
                echo "请在完成后执行以下命令重载 Nginx 配置："
                echo "docker exec $CONTAINER_NAME nginx -s reload"
            else
                echo "错误：删除 server 块失败"
            fi
            ;;
        
        3)
            # 查看 server 块代理端口
            echo "当前 server 块域名及其代理端口："
            awk '
            BEGIN { domain = ""; port = "" }
            # 匹配 server_name 行，提取域名
            /[[:space:]]*server_name[[:space:]]+[^;]+;/ {
                sub(/[[:space:]]*server_name[[:space:]]+/, ""); 
                sub(/;.*/, ""); 
                domain = $0
            }
            # 匹配 proxy_pass 行，提取端口
            /[[:space:]]*proxy_pass[[:space:]]+http:\/\/127\.0\.0\.1:[0-9]+/ {
                match($0, /:[0-9]+/); 
                port = substr($0, RSTART+1, RLENGTH-1)
            }
            # 当遇到结束括号时输出
            /^[[:space:]]*}/ {
                if (domain != "" && port != "") {
                    print "  " domain " -> 127.0.0.1:" port
                }
                domain = ""; port = ""
            }
            ' "$CONFIG_FILE" | sort

            # 检查是否有 server 块
            if [ -z "$(grep -oP 'server_name\s+\K[^;]+' "$CONFIG_FILE")" ]; then
                echo "  (无任何 server 块)"
            fi
            ;;
        
        4)
            echo "退出脚本"
            exit 0
            ;;
        
        *)
            echo "错误：无效选项，请输入 1-4"
            ;;
    esac

    echo "" # 添加空行以提高可读性
done