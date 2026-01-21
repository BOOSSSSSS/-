#!/bin/bash
set -euo pipefail

CONFIG_DIR="/etc/gost"

# ===== 颜色 =====
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ===== 区旗 =====
flag() {
    case "$1" in
        HK) echo "🇭🇰" ;;
        TW) echo "🇹🇼" ;;
        JP) echo "🇯🇵" ;;
        SG) echo "🇸🇬" ;;
        US) echo "🇺🇸" ;;
        CN) echo "🇨🇳" ;;
        *)  echo "🌐" ;;
    esac
}

# ===== IP 信息 =====
ip_info() {
    curl -s --max-time 3 "http://ip-api.com/json/$1?fields=status,country,countryCode" |
    jq -r 'if .status=="success"
           then "\(.countryCode)|\(.country)"
           else "UNK|Unknown"
           end'
}

# ===== 选择配置文件 =====
configs=("$CONFIG_DIR"/*.json)
[ ${#configs[@]} -eq 0 ] && echo -e "${RED}未找到 GOST 配置文件${NC}" && exit 1

echo -e "${GREEN}可用配置文件:${NC}"
select CONFIG in "${configs[@]}"; do
    [ -n "$CONFIG" ] && break
done

RAW="/tmp/gost_raw.$$"
SORTED="/tmp/gost_sorted.$$"
> "$RAW"

# ===== 提取 IP =====
jq -r '
.services[] |
  .name as $svc |
  .forwarder.nodes[] |
  [$svc, .name, .addr] | @tsv
' "$CONFIG" | while IFS=$'\t' read -r svc node addr; do
    ip="${addr%:*}"
    port="${addr#*:}"
    info="$(ip_info "$ip")"
    cc="${info%%|*}"
    country="${info#*|}"
    echo "$country|$(flag "$cc")|$svc|$node|$ip|$port" >> "$RAW"
done

# ===== 排序 + 编号（唯一数据源，核心修复点）=====
nl -w2 -s'|' <(sort "$RAW") > "$SORTED"

# ===== 显示列表 =====
echo -e "\n${GREEN}IP 分组列表:${NC}"
while IFS='|' read -r idx country flag svc node ip port; do
    printf "[%s] %-14s %s %-15s %-6s %s/%s\n" \
        "$idx" "$country" "$flag" "$ip" "$port" "$svc" "$node"
done < "$SORTED"

total=$(wc -l < "$SORTED")
echo ""
read -p "选择要替换的序号 (1-$total): " idx

# ===== 严格从 SORTED 取值 =====
line=$(awk -F'|' -v i="$idx" '$1==i {print}' "$SORTED")
[ -z "$line" ] && echo -e "${RED}无效序号${NC}" && exit 1

IFS='|' read -r _ country flag svc node old_ip port <<< "$line"

echo -e "\n已选择: ${flag} ${country} ${old_ip}:${port}"

same_count=$(grep -F "|$country|" "$SORTED" | wc -l)
read -p "是否替换该地区全部 $same_count 个 IP? (y/N): " replace_all

read -p "请输入新 IP: " new_ip
[[ ! "$new_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && echo -e "${RED}IP 格式错误${NC}" && exit 1

backup="$CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG" "$backup"

# ===== 执行替换 =====
if [[ "$replace_all" =~ ^[Yy]$ ]]; then
    grep -F "|$country|" "$SORTED" | while IFS='|' read -r _ _ _ svc node ip port; do
        jq --arg s "$svc" --arg n "$node" --arg a "$new_ip:$port" \
           '(.services[] | select(.name==$s)
             .forwarder.nodes[] | select(.name==$n).addr)=$a' \
           "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    done
    echo -e "${GREEN}已替换 ${country} 地区全部 IP${NC}"
else
    jq --arg s "$svc" --arg n "$node" --arg a "$new_ip:$port" \
       '(.services[] | select(.name==$s)
         .forwarder.nodes[] | select(.name==$n).addr)=$a' \
       "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    echo -e "${GREEN}IP 替换完成${NC}"
fi

echo -e "${YELLOW}配置已备份:${NC} $backup"

rm -f "$RAW" "$SORTED"
