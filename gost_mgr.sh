#!/bin/bash

# --- 0. 基础配置 ---
CONF_FILE="/etc/gost/gost.json"
BACKUP_DIR="/etc/gost/backups"

# --- 1. 环境准备 ---
[ "$EUID" -ne 0 ] && echo "❌ 请使用 sudo 运行" && exit 1
command -v jq &> /dev/null || (apt update && apt install jq -y || yum install jq -y)
mkdir -p $BACKUP_DIR

# --- 2. 深度自动匹配预览 (不锁定路径) ---
clear
echo "=============================="
echo "    Gost 落地配置预览 (全解析模式)"
echo "=============================="

if [ -s "$CONF_FILE" ]; then
    # 逻辑：
    # 1. .. 深度递归寻找所有 addr 键
    # 2. test("^[0-9]+\\.") 强制要求内容必须以数字开头并带点(IP特征)
    # 3. 排除以 ":" 开头的端口号
    DATA=$(jq -r '
        .services[]? | . as $svc | 
        $svc.addr as $port | 
        ($svc | .. | .addr? | select(. != null and test("^[0-9]+\\.") and (contains(":") or test("^[0-9.]+$")))) as $ip |
        "\($port) \t \($ip)"
    ' "$CONF_FILE" 2>/dev/null)

    if [ -z "$DATA" ]; then
        echo "💡 提示：未能自动识别映射。请选 4 手动确认。"
    else
        echo -e "监听端口\t| 落地 IP 列表"
        echo "------------------------------------------"
        # 统一清理冒号前缀和后缀，只留 IP
        echo "$DATA" | sed 's/:[0-9]\{1,5\}//g; s/://g' | \
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
            echo -e "\n✅ 修改已应用！"
        else
            echo -e "\n⚠️ Gost 校验失败，请选 4 检查语法。"
        fi
    else
        echo -e "\n❌ 严重：JSON 结构损坏，回滚修改。"
        rm -f "$temp"
    fi
}

# --- 4. 菜单 ---
echo "1) 增加/修改 (全结构适配)"
echo "2) 删除端口"
echo "3) 全局替换 IP"
echo "4) 手动编辑 (Nano)"
echo "5) 退出"
read -p "选择 [1-5]: " OPT

case $OPT in
    1)
        read -p "端口: " PORT
        read -p "落地IP (逗号隔开): " IPS
        do_backup
        [ ! -s "$CONF_FILE" ] && echo '{"services": []}' > "$CONF_FILE"
        
        IPS_JSON=$(echo $IPS | sed 's/,/ /g' | awk '{for(i=1;i<=NF;i++) printf "{\"addr\":\"%s:1002\"}%s", $i, (i==NF?"":",")}')
        
        # 智能修改：不锁路径，哪里有 forwarder 改哪里，没有就建一个平级的
        jq --arg port ":$PORT" --argjson nodes "[$IPS_JSON]" \
        '(.services[]? | select(.addr == $port)) |= (
            if has("forwarder") then .forwarder.nodes = $nodes
            elif (.handler | has("forwarder")) then .handler.forwarder.nodes = $nodes
            else . + {forwarder: {nodes: $nodes}} end
        ) | 
        if (.services | any(.addr == $port)) then . 
        else .services += [{name: ("svc"+$port), addr: $port, handler: {type: "relay"}, listener: {type: "tls"}, forwarder: {nodes: $nodes}}] end' \
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
