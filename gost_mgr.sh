#!/bin/bash

CONF_FILE="/etc/gost/gost.json"
BACKUP_DIR="/etc/gost/backups"
IP_CACHE="/tmp/gost_ip_region.cache"

# ---------- 基础 ----------
[ "$EUID" -ne 0 ] && echo "❌ 请使用 root / sudo 运行" && exit 1
command -v jq >/dev/null || (apt update && apt install jq -y || yum install jq -y)
mkdir -p "$BACKUP_DIR"

# ---------- 国家码 → 国旗 ----------
flag() {
    local c="$1"
    case "$c" in
        CN) echo "🇨🇳" ;;
        US) echo "🇺🇸" ;;
        JP) echo "🇯🇵" ;;
        KR) echo "🇰🇷" ;;
        SG) echo "🇸🇬" ;;
        HK) echo "🇭🇰" ;;
        TW) echo "🇹🇼" ;;
        DE) echo "🇩🇪" ;;
        FR) echo "🇫🇷" ;;
        GB) echo "🇬🇧" ;;
        IT) echo "🇮🇹" ;;
        NL) echo "🇳🇱" ;;
        *)  echo "🏳️" ;;
    esac
}

# ---------- IP → 地区（带缓存） ----------
get_ip_region() {
    local ip="$1"

    if grep -q "^$ip|" "$IP_CACHE" 2>/dev/null; then
        grep "^$ip|" "$IP_CACHE" | cut -d'|' -f2-
        return
    fi

    local info country region city
    info=$(curl -s --max-time 2 "https://ipinfo.io/$ip/json")

    country=$(echo "$info" | jq -r '.country // "?"')
    region=$(echo "$info" | jq -r '.region // ""')
    city=$(echo "$info" | jq -r '.city // ""')

    local f
    f=$(flag "$country")

    local text="$f $country $region $city"
    echo "$ip|$text" >> "$IP_CACHE"
    echo "$text"
}

clear
echo "=============================="
echo "   Gost 落 地 配 置 预 览（运维版）"
echo "=============================="
echo "监听端口 | 落地 IP（地区 / 复用）"
echo "------------------------------------------"

# ---------- 解析 JSON ----------
mapfile -t LINES < <(
jq -r '
.services[]
| .addr as $port
| (.forwarder.nodes[].addr | sub(":1002$"; "")) as $ip
| "\($port | sub("^:";""))|\($ip)"
' "$CONF_FILE" | sort -n
)

# ---------- 统计 IP 复用 ----------
declare -A IP_COUNT
declare -A PORTS_BY_IP

for l in "${LINES[@]}"; do
    ip="${l#*|}"
    port="${l%%|*}"
    ((IP_COUNT["$ip"]++))
    PORTS_BY_IP["$ip"]+="$port "
done

# ---------- 地区分组 ----------
declare -A GROUP

for ip in "${!IP_COUNT[@]}"; do
    region=$(get_ip_region "$ip")
    GROUP["$region"]+="$ip "
done

# ---------- 输出 ----------
for region in "${!GROUP[@]}"; do
    echo
    echo "【 $region 】"
    for ip in ${GROUP[$region]}; do
        ports="${PORTS_BY_IP[$ip]}"
        count="${IP_COUNT[$ip]}"
        for p in $ports; do
            if [ "$count" -gt 1 ]; then
                printf "%-8s | %-15s 🔁x%d\n" "$p" "$ip" "$count"
            else
                printf "%-8s | %-15s\n" "$p" "$ip"
            fi
        done
    done
done

echo
echo "=============================="
echo "1) 增加 / 修改"
echo "2) 删除端口"
echo "3) 全局替换 IP"
echo "4) 手动编辑 (Nano)"
echo "5) 退出"
read -p "选择 [1-5]: " OPT

do_backup() {
    [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "$BACKUP_DIR/gost_$(date +%F_%T).bak"
}

apply_conf() {
    if gost -verify -F "$CONF_FILE" >/dev/null 2>&1; then
        systemctl restart gost
        echo "✅ 配置已生效"
    else
        echo "❌ Gost 校验失败"
    fi
}

case "$OPT" in
1)
    read -p "端口: " PORT
    read -p "IP (逗号): " IPS
    do_backup
    [ ! -s "$CONF_FILE" ] && echo '{"services":[]}' > "$CONF_FILE"

    NODES=$(echo "$IPS" | sed 's/,/ /g' | awk '{for(i=1;i<=NF;i++)printf "{\"name\":\"node_%d\",\"addr\":\"%s:1002\"}%s",i,$i,(i==NF?"":",")}')

    jq --arg port ":$PORT" --argjson nodes "[$NODES]" '
    if (.services | any(.addr==$port)) then
      (.services[] | select(.addr==$port) | .forwarder.nodes)=$nodes
    else
      .services += [{
        name: "auto_'$PORT'",
        addr: $port,
        handler:{type:"relay"},
        listener:{type:"tls"},
        forwarder:{selector:{strategy:"fifo",maxFails:1,failTimeout:600000000000},nodes:$nodes}
      }]
    end' "$CONF_FILE" > "$CONF_FILE.tmp" && mv "$CONF_FILE.tmp" "$CONF_FILE"
    apply_conf
;;
2)
    read -p "删除端口: " PORT
    do_backup
    jq 'del(.services[] | select(.addr==":'"$PORT"'"))' "$CONF_FILE" > "$CONF_FILE.tmp" && mv "$CONF_FILE.tmp" "$CONF_FILE"
    apply_conf
;;
3)
    read -p "旧 IP: " O; read -p "新 IP: " N
    do_backup
    sed -i "s/$O/$N/g" "$CONF_FILE"
    apply_conf
;;
4)
    do_backup
    nano "$CONF_FILE"
    apply_conf
;;
*)
    exit 0
;;
esac
