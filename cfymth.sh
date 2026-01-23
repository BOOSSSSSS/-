#!/bin/bash

# ================= 配置区域 =================
API_TOKEN="你的_CF_API_令牌"
OLD_IP="1.1.1.1"        # 搜索的旧 IP
NEW_IP="2.2.2.2"        # 替换为的新 IP
# ===========================================

# 获取所有域名 (Zones)
echo "[*] 正在获取域名列表..."
ZONES=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?per_page=50" \
     -H "Authorization: Bearer $API_TOKEN" \
     -H "Content-Type: application/json" | jq -r '.result[] | "\(.id)|\(.name)"')

if [ -z "$ZONES" ]; then
    echo "[!] 未找到域名或 API Token 无效。"
    exit 1
fi

for ZONE in $ZONES; do
    ZONE_ID=$(echo $ZONE | cut -d'|' -f1)
    ZONE_NAME=$(echo $ZONE | cut -d'|' -f2)

    echo "[*] 正在扫描域名: $ZONE_NAME"

    # 搜索该域名下所有匹配旧 IP 的 A 记录
    RECORDS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&content=$OLD_IP" \
         -H "Authorization: Bearer $API_TOKEN" \
         -H "Content-Type: application/json" | jq -c '.result[]')

    if [ -z "$RECORDS" ]; then
        continue
    fi

    # 遍历并更新匹配的记录
    echo "$RECORDS" | while read -r record; do
        RECORD_ID=$(echo $record | jq -r '.id')
        RECORD_NAME=$(echo $record | jq -r '.name')
        TTL=$(echo $record | jq -r '.ttl')
        PROXIED=$(echo $record | jq -r '.proxied')

        echo "  [+] 发现记录 $RECORD_NAME ($RECORD_ID)，正在更新..."

        # 执行更新
        RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
             -H "Authorization: Bearer $API_TOKEN" \
             -H "Content-Type: application/json" \
             --data "{\"type\":\"A\",\"name\":\"$RECORD_NAME\",\"content\":\"$NEW_IP\",\"ttl\":$TTL,\"proxied\":$PROXIED}" \
             | jq -r '.success')

        if [ "$RESULT" = "true" ]; then
            echo "    [OK] 更新成功: $OLD_IP -> $NEW_IP"
        else
            echo "    [ERROR] 更新失败"
        fi
    done
done

echo "[*] 所有操作已完成。"
