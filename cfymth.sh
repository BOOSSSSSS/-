#!/bin/bash

# --- 1. 自动依赖检测与安装 ---
install_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "检测到缺少依赖: $1，正在尝试安装..."
        if [ -f /etc/debian_version ]; then
            sudo apt-get update && sudo apt-get install -y "$1"
        elif [ -f /etc/redhat-release ]; then
            sudo yum install -y "$1"
        else
            echo "无法识别系统，请手动安装 $1 后再运行。"
            exit 1
        fi
    fi
}

install_dependency "curl"
install_dependency "jq"

# --- 2. 交互式输入区域 ---
echo "=========================================="
echo "    Cloudflare DNS 记录一键替换工具"
echo "=========================================="

# 输入 API Token
read -p "请输入 Cloudflare API Token: " API_TOKEN
if [ -z "$API_TOKEN" ]; then echo "Token 不能为空"; exit 1; fi

# 输入旧 IP
read -p "请输入要替换的旧 IP (OLD IP): " OLD_IP
if [ -z "$OLD_IP" ]; then echo "旧 IP 不能为空"; exit 1; fi

# 输入新 IP
read -p "请输入目标新 IP (NEW IP): " NEW_IP
if [ -z "$NEW_IP" ]; then echo "新 IP 不能为空"; exit 1; fi

echo -e "\n[*] 正在验证 Token 并拉取域名列表..."

# --- 3. 获取并处理数据 ---
# 获取所有 Zone
ZONES_JSON=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?per_page=100" \
     -H "Authorization: Bearer $API_TOKEN" \
     -H "Content-Type: application/json")

if [[ $(echo "$ZONES_JSON" | jq -r '.success') != "true" ]]; then
    echo "[!] 出错: 无法连接 Cloudflare API。请检查 Token 是否正确且具有 '区域.区域(读)' 权限。"
    echo "错误详情: $(echo "$ZONES_JSON" | jq -r '.errors[0].message')"
    exit 1
fi

ZONE_LIST=$(echo "$ZONES_JSON" | jq -r '.result[] | "\(.id)|\(.name)"')

echo "[+] 成功获取域名列表，开始扫描包含 IP: $OLD_IP 的记录..."
echo "------------------------------------------"

count=0
for ZONE in $ZONE_LIST; do
    ZONE_ID=$(echo $ZONE | cut -d'|' -f1)
    ZONE_NAME=$(echo $ZONE | cut -d'|' -f2)

    # 获取匹配的 DNS 记录
    RECORDS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&content=$OLD_IP" \
         -H "Authorization: Bearer $API_TOKEN" \
         -H "Content-Type: application/json" | jq -c '.result[]')

    if [ -z "$RECORDS" ]; then
        continue
    fi

    echo "[*] 在域名 $ZONE_NAME 下发现匹配记录:"
    
    echo "$RECORDS" | while read -r record; do
        RID=$(echo $record | jq -r '.id')
        RNAME=$(echo $record | jq -r '.name')
        RPROXIED=$(echo $record | jq -r '.proxied')
        RTTL=$(echo $record | jq -r '.ttl')

        # 执行更新
        echo -n "    正在更新 $RNAME ... "
        UPDATE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" \
             -H "Authorization: Bearer $API_TOKEN" \
             -H "Content-Type: application/json" \
             --data "{\"type\":\"A\",\"name\":\"$RNAME\",\"content\":\"$NEW_IP\",\"ttl\":$RTTL,\"proxied\":$RPROXIED}")

        if [[ $(echo "$UPDATE" | jq -r '.success') == "true" ]]; then
            echo "成功！"
        else
            echo "失败: $(echo "$UPDATE" | jq -r '.errors[0].message')"
        fi
    done
    ((count++))
done

if [ $count -eq 0 ]; then
    echo "[!] 未在任何域名下找到包含 IP $OLD_IP 的 A 记录。"
fi

echo "------------------------------------------"
echo "[*] 任务完成。"
