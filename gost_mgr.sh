#!/bin/bash

CONF_FILE="/etc/gost/gost.json"
BACKUP_DIR="/etc/gost/backups"
IP_CACHE="/tmp/gost_ip_region.cache"

# ---------- 基础 ----------
[ "$EUID" -ne 0 ] && echo "❌ 请使用 root / sudo 运行" && exit 1
command -v jq >/dev/null || (apt update && apt install -y jq || yum install -y jq)
mkdir -p "$BACKUP_DIR"

# ---------- 国旗函数 ----------
flag() {
    case "$1" in
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

# ---------- IP → 中文地区（缓存） ----------
get_ip_region() {
    local ip="$1"
    if grep -q "^$ip|" "$IP_CACHE" 2>/dev/null; then
        grep "^$ip|" "$IP_CACHE" | cut -d'|' -f2-
        return
    fi
    local info country region city cname
    info=$(curl -s --max-time 2 "https://ipinfo.io/$ip/json")
    country=$(echo "$info" | jq -r '.country // "?"')
    region=$(echo "$info" | jq -r '.region // ""')
    city=$(echo "$info" | jq -r '.city // ""')
    case "$country" in
        CN) cname="中国" ;;
        US) cname="美国" ;;
        JP) cname="日本" ;;
        KR) cname="韩国" ;;
        SG) cname="新加坡" ;;
        HK) cname="香港" ;;
        TW) cname="台湾" ;;
        DE) cname="德国" ;;
        FR) cname="法国" ;;
        GB) cname="英国" ;;
        IT) cname="意大利" ;;
        NL) cname="荷兰" ;;
        *) cname="$country" ;;
    esac
    local f
    f=$(flag "$country")
    local text="$f $cname $region $city"
    echo "$ip|$text" >> "$IP_CACHE"
    echo "$text"
}

# ---------- 备份 ----------
do_backup() { [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "$BACKUP_DIR/gost_$(date +%F_%T).bak"; }

# ---------- 安全应用 ----------
apply_conf() {
    local TMP="$1"
    echo "🔹 开始 Gost 校验..."
    
    gost -verify -F "$TMP" 2>&1
    if [ $? -eq 0 ]; then
        do_backup
        mv "$TMP" "$CONF_FILE"
        systemctl restart gost
        echo "✅ 配置已生效，服务已重启"
    else
        echo "❌ 校验失败，修改未应用，详细 Gost 错误如下："
        gost -verify -F "$TMP" 2>&1
        rm -f "$TMP"
    fi
}

# ---------- 预览 ----------
clear
echo "=============================="
echo "   Gost 落地配置预览（中文版运维版）"
echo "=============================="
echo "监听端口 | 落地 IP（地区 / 复用）"
echo "------------------------------------------"

mapfile -t LINES < <(
jq -r '.services[] | .addr as $port | (.forwarder.nodes[].addr | sub(":1002$"; "")) as $ip | "\($port | sub("^:";""))|\($ip)"' "$CONF_FILE" | sort -n
)

declare -A IP_COUNT PORTS_BY_IP
for l in "${LINES[@]}"; do
    ip="${l#*|}"
    port="${l%%|*}"
    ((IP_COUNT["$ip"]++))
    PORTS_BY_IP["$ip"]+="$port "
done

declare -A GROUP
for ip in "${!IP_COUNT[@]}"; do
    region=$(get_ip_region "$ip")
    GROUP["$region"]+="$ip "
done

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
echo "=============================="
echo "1) 增加 / 修改 单端口"
echo "1a) 按地区增/删/替换 IP"
echo "2) 删除端口"
echo "3) 全局替换 IP"
echo "4) 手动编辑 (Nano)"
echo "5) 退出"
read -p "选择 [1-5 / 1a]: " OPT

# ---------- 按地区增删替 IP ----------
region_ip_modify() {
    TMP=$(mktemp)
    cp "$CONF_FILE" "$TMP"
    for ip in $(jq -r '.services[].forwarder.nodes[].addr | sub(":1002$"; "")' "$TMP"); do
        r=$(get_ip_region "$ip")
        if [[ "$r" == "$REGION" ]]; then
            PORTS=$(jq -r --arg IP "$ip" '.services[] | select(.forwarder.nodes[].addr | sub(":1002$"; "")==$IP) | .addr' "$TMP")
            for p in $PORTS; do
                case "$ACT" in
                1) # 增加 IP
                    for NEW_IP in $(echo $USER_IPS | tr ',' ' '); do
                        EXISTS=$(jq --arg port "$p" --arg ip "$NEW_IP" '.services[] | select(.addr==$port) | .forwarder.nodes[] | select(.addr==($ip+":1002"))' "$TMP")
                        if [ -z "$EXISTS" ]; then
                            NODE_NAME="node_$(date +%s%N)"
                            jq --arg port "$p" --arg ip "$NEW_IP" --arg name "$NODE_NAME" \
                               '(.services[] | select(.addr==$port) | .forwarder.nodes) += [{"name":$name,"addr":($ip+":1002")}]' \
                               "$TMP" > "${TMP}.tmp" && mv "${TMP}.tmp" "$TMP"
                        fi
                    done
                    ;;
                2) # 删除 IP
                    for DEL_IP in $(echo $USER_IPS | tr ',' ' '); do
                        jq --arg port "$p" --arg ip "$DEL_IP" \
                           '(.services[] | select(.addr==$port) | .forwarder.nodes) |= map(select(.addr != ($ip+":1002")))' \
                           "$TMP" > "${TMP}.tmp" && mv "${TMP}.tmp" "$TMP"
                    done
                    ;;
                3) # 替换 IP
                    for REPL_IP in $(echo $USER_IPS | tr ',' ' '); do
                        NODE_NAME="node_$(date +%s%N)"
                        jq --arg port "$p" --arg ip "$REPL_IP" --arg name "$NODE_NAME" \
                           '(.services[] | select(.addr==$port) | .forwarder.nodes) = [{"name":$name,"addr":($ip+":1002")}]' \
                           "$TMP" > "${TMP}.tmp" && mv "${TMP}.tmp" "$TMP"
                    done
                    ;;
                esac
            done
        fi
    done
    apply_conf "$TMP"
}

# ---------- 主菜单 ----------
case "$OPT" in
1)
    read -p "端口: " PORT
    read -p "IP (逗号分隔): " IPS
    [ ! -s "$CONF_FILE" ] && echo '{"services":[]}' > "$CONF_FILE"
    TMP=$(mktemp)
    cp "$CONF_FILE" "$TMP"
    for NEW_IP in $(echo "$IPS" | tr ',' ' '); do
        NODE_NAME="node_$(date +%s%N)"
        jq --arg port ":$PORT" --arg ip "$NEW_IP" --arg name "$NODE_NAME" \
           'if (.services | any(.addr==$port)) then
                (.services[] | select(.addr==$port) | .forwarder.nodes) += [{"name":$name,"addr":($ip+":1002")}]
            else
                .services += [{
                    name: "auto_'$PORT'",
                    addr: $port,
                    handler:{type:"relay"},
                    listener:{type:"tls"},
                    forwarder:{selector:{strategy:"fifo",maxFails:1,failTimeout:600000000000},nodes:[{"name":$name,"addr":($ip+":1002")}]}
                }]
            end' "$TMP" > "${TMP}.tmp" && mv "${TMP}.tmp" "$TMP"
    done
    apply_conf "$TMP"
    ;;
1a)
    echo "可操作地区列表："
    mapfile -t REGION_LIST < <(
        jq -r '.services[].forwarder.nodes[].addr | sub(":1002$"; "")' "$CONF_FILE" | while read ip; do get_ip_region "$ip"; done | sort -u
    )
    for i in "${!REGION_LIST[@]}"; do
        printf "%d) %s\n" "$i" "${REGION_LIST[$i]}"
    done
    read -p "选择地区编号: " IDX
    REGION="${REGION_LIST[$IDX]}"
    echo "操作类型："
    echo "1) 增加 IP"
    echo "2) 删除 IP"
    echo "3) 替换 IP"
    read -p "选择 [1-3]: " ACT
    read -p "输入 IP（逗号分隔）: " USER_IPS
    region_ip_modify
    ;;
2)
    read -p "删除端口: " PORT
    TMP=$(mktemp)
    cp "$CONF_FILE" "$TMP"
    jq 'del(.services[] | select(.addr==":'"$PORT"'"))' "$TMP" > "${TMP}.tmp" && mv "${TMP}.tmp" "$TMP"
    apply_conf "$TMP"
    ;;
3)
    read -p "旧 IP: " OLD
    read -p "新 IP: " NEW
    TMP=$(mktemp)
    cp "$CONF_FILE" "$TMP"
    sed -i "s/$OLD/$NEW/g" "$TMP"
    apply_conf "$TMP"
    ;;
4)
    nano "$CONF_FILE"
    apply_conf "$CONF_FILE"
    ;;
*)
    exit 0
    ;;
esac
