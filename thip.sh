#!/bin/bash
set -e

CONFIG_DIR="/etc/gost"

# ========= 颜色 =========
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ========= 国家 / 地区 → 国旗 =========
flag() {
    case "$1" in
        CN) echo "🇨🇳" ;;   # 中国大陆
        HK) echo "🇭🇰" ;;   # 香港
        TW) echo "🇹🇼" ;;   # 台湾
        MO) echo "🇲🇴" ;;   # 澳门
        US) echo "🇺🇸" ;;
        JP) echo "🇯🇵" ;;
        KR) echo "🇰🇷" ;;
        SG) echo "🇸🇬" ;;
        DE) echo "🇩🇪" ;;
        FR) echo "🇫🇷" ;;
        GB) echo "🇬🇧" ;;
        *)  echo "🌐" ;;
    esac
}

# ========= IP 地理信息 =========
ip_info() {
    curl -s "http://ip-api.com/json/$1?fields=status,country,countryCode" |
    jq -r 'if .status=="success"
           then "\(.countryCode)|\(.country)"
           else "UNK|未知"
           end'
}

# ========= 选择配置文件 =========
configs=("$CONFIG_DIR"/*.json)
[ ${#configs[@]} -eq 0 ] && echo -e "${RED}未找到 GOST 配置文件${NC}" && exit 1

echo -e "${GREEN}可用配置文件:${NC}"
select CONFIG in "${configs[@]}"; do
    [ -n "$CONFIG" ] && break
done

# ========= 提取 IP =========
TMP="/tmp/gost_ips.$$"
> "$TMP"

jq -r '
.services[] |
  .name as $svc |
  .forwarder.nodes[] |
  [$svc, .name, .addr] | @tsv
' "$CONFIG" | while IFS=$'\t' read svc node addr; do
    ip=${addr%:*}
    port=${addr#*:}
    info=$(ip_info "$ip")
    cc=${info%%|*}
    country=${info#*|}
    echo "$country|$(flag "$cc")|$svc|$node|$ip|$port" >> "$TMP"
done

# ========= 显示分组 =========
echo -e "\n${GREEN}IP 分组列表:${NC}"
i=1
sort "$TMP" | while IFS='|' read country flag svc node ip port; do
    printf "[%d] %-10s %s %-15s %-6s %s/%s\n" \
        "$i" "$country" "$flag" "$ip" "$port" "$svc" "$node"
    i=$((i+1))
done

total=$(wc -l < "$TMP")
echo ""
read -p "选择要替换的序号 (1-$total): " idx

line=$(sed -n "${idx}p" "$TMP")
IFS='|' read country flag svc node old_ip port <<< "$line"

echo -e "\n已选择: ${flag} ${country} ${old_ip}:${port}"

# ========= 同地区统计 =========
same_count=$(grep "^$country|" "$TMP" | wc -l)

read -p "是否替换该地区全部 $same_count 个IP? (y/N): " replace_all

read -p "请输入新 IP: " new_ip
if [[ ! "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}IP 格式错误${NC}"
    exit 1
fi

# ========= 备份 =========
backup="$CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG" "$backup"

# ========= 执行替换 =========
if [[ "$replace_all" =~ ^[Yy]$ ]]; then
    grep "^$country|" "$TMP" | while IFS='|' read _ _ svc node ip port; do
        jq --arg s "$svc" --arg n "$node" --arg a "$new_ip:$port" \
           '(.services[]|select(.name==$s).forwarder.nodes[]|select(.name==$n).addr)=$a' \
           "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    done
    echo -e "${GREEN}已替换 ${country} 地区全部 IP${NC}"
else
    jq --arg s "$svc" --arg n "$node" --arg a "$new_ip:$port" \
       '(.services[]|select(.name==$s).forwarder.nodes[]|select(.name==$n).addr)=$a' \
       "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    echo -e "${GREEN}IP 替换完成${NC}"
fi

echo -e "${YELLOW}备份文件:${NC} $backup"
rm -f "$TMP"
