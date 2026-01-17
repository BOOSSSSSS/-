#!/bin/bash

CONF_FILE="/etc/gost/gost.json"
BACKUP_DIR="/etc/gost/backups"

# --- 1. 环境准备 ---
[ "$EUID" -ne 0 ] && echo "❌ 请使用 sudo 运行" && exit 1
command -v jq &> /dev/null || (apt update && apt install jq -y || yum install jq -y)
mkdir -p $BACKUP_DIR

# --- 2. 深度关联解析预览 (修复显示错位) ---
clear
echo "=============================="
echo "    Gost 落地配置预览 (智能关联版)"
echo "=============================="

if [ -s "$CONF_FILE" ]; then
    # 逻辑：
    # 1. 遍历 .services[] 每个对象
    # 2. .addr 必定是监听端口
    # 3. 在当前对象下递归查找所有带 "." 的 addr，作为落地 IP
    DATA=$(jq -r '
        .services[]? | . as $svc | 
        ($svc.addr | sub("^:"; "")) as $p | 
        [ $svc | .. | .addr? | select(. != null and contains(".")) ] | unique |
        if length > 0 then
            .[] | "\($p) \t \(.)"
        else
            "\($p) \t (暂无落地)"
        end
    ' "$CONF_FILE" 2>/dev/null)

    if [ -z "$DATA" ]; then
        echo "💡 提示：未能识别到有效的配置映射。"
    else
        echo -e "监听端口\t| 落地 IP 列表"
        echo "------------------------------------------"
        # 清理 IP 后缀并合并显示
        echo "$DATA" | sed 's/:[0-9]\{1,5\}//g' | \
        awk '{a[$1]=a[$1] $2 ","} END {for(i in a) {sub(/,$/, "", a[i]); printf "%-15s | %s\n", i, a[i]}}' | sort -n
    fi
else
    echo "🆕 配置文件为空。"
fi
echo "=============================="

# --- 3. 核心功能函数 ---

do_backup() {
    [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "$BACKUP_DIR/gost_$(date +%Y%m%d_%H%M%S).json.bak"
}

apply_conf() {
    temp=$(mktemp)
    if jq . "$CONF_FILE" > "$temp" 2>/dev/null; then
        mv "$temp" "$CONF_FILE"
        if gost -verify -F "$CONF_FILE" > /dev/null 2>&1; then
            ip link set dev $(ip route get 8.8.8.8 | awk '{print $5; exit}') mtu 1380
            systemctl restart gost
            echo -e "\n✅ 配置已生效！"
        else
            echo -e "\n⚠️ Gost 语法校验失败，请选 4 检查。"
        fi
    else
        echo -e "\n❌ JSON 损坏，修改未保存。"
        rm -f "$temp"
    fi
}

# --- 4. 交互菜单 ---
echo "1) 增加/修改 (全结构适配)"
echo "2) 删除端口"
echo "3) 全局替换 IP"
echo "4) 手动编辑 (Nano)"
echo "5) 退出"
read -p "选择 [1-5]: " OPT

case $OPT in
    1)
        read -p "端口 (如 12701): " PORT
        read -p "落地IP (逗号隔开): " IPS
        do_backup
        [ ! -s "$CONF_FILE" ] && echo '{"services": []}' > "$CONF_FILE"
        
        IPS_JSON=$(echo $IPS | sed 's/,/ /g' | awk '{for(i=1;i<=NF;i++) printf "{\"name\":\"node_%d\",\"addr\":\"%s:1002\"}%s", i, $i, (i==NF?"":",")}')
        
        jq --arg port ":$PORT" --argjson nodes "[$IPS_JSON]" \
        '(.services[]? | select(.addr == $port)) |= (
            if has("forwarder") then .forwarder.nodes = $nodes
            elif (.handler | has("forwarder")) then .handler.forwarder.nodes = $nodes
            else . + {forwarder: {nodes: $nodes}} end
        ) | 
        if (.services | any(.addr == $port)) then . 
        else .services += [{name: ("svc"+($port|sub("^:"; ""))), addr: $port, handler: {type: "relay"}, listener: {type: "tls"}, forwarder: {nodes: $nodes}}] end' \
        "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
        apply_conf
        ;;
    2)
        read -p "删除端口: " PORT
        do_backup
        jq --arg port ":$PORT" 'del(.services[]? | select(.addr == $port))' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
        apply_conf
        ;;
    3)
        read -p "旧 IP: " OLD
        read -p "新 IP: " NEW
        do_backup
        sed -i "s/$OLD/$NEW/g" "$CONF_FILE"
        apply_conf
        ;;
    4)
        do_backup
        nano "$CONF_FILE"
        apply_conf
        ;;
    *) exit 0 ;;
esac
