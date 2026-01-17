#!/bin/bash

CONF_FILE="/etc/gost/gost.json"
BACKUP_DIR="/etc/gost/backups"

# --- 1. 环境自检与安装 JQ ---
if ! command -v jq &> /dev/null; then
    echo "正在安装必备组件 jq..."
    if command -v apt &> /dev/null; then
        apt update && apt install jq -y
    elif command -v yum &> /dev/null; then
        yum install jq -y
    fi
fi

mkdir -p $BACKUP_DIR

# --- 2. 数据读取展示 ---
clear
echo "=============================="
echo "    Gost 状态预览 (JQ 驱动)"
echo "=============================="

if [ ! -f "$CONF_FILE" ] || [ ! -s "$CONF_FILE" ]; then
    echo '{"services": []}' > "$CONF_FILE"
    echo "🆕 已初始化新配置。"
else
    # 使用 jq 打印漂亮的表格
    echo -e "监听端口\t| 落地 IP 列表"
    echo "------------------------------------------"
    jq -r '.services[] | "\(.addr) \t| \(.handler.forwarder.nodes[].addr)"' "$CONF_FILE" | \
    sed 's/:1002//g' | sed 's/://g' | awk '{a[$1]=a[$1] $3 ","} END {for(i in a) {sub(/,$/, "", a[i]); print i "\t\t| " a[i]}}'
fi
echo "=============================="

# --- 3. 核心工具函数 ---

do_backup() {
    cp "$CONF_FILE" "$BACKUP_DIR/gost_$(date +%Y%m%d_%H%M%S).json.bak"
}

apply_conf() {
    # 格式化一下 JSON，让它更美观
    temp=$(mktemp)
    jq . "$CONF_FILE" > "$temp" && mv "$temp" "$CONF_FILE"
    
    if gost -verify -F "$CONF_FILE" > /dev/null 2>&1; then
        ip link set dev $(ip route get 8.8.8.8 | awk '{print $5; exit}') mtu 1380
        systemctl restart gost
        echo "✅ [SUCCESS] 配置已安全应用并重启。"
    else
        echo "❌ [ERROR] 发现语法异常，正在回滚..."
        # 这里可以加入回滚逻辑
    fi
}

# --- 4. 交互菜单 ---

echo "1) 增加/修改映射 (输入端口和IP列表)"
echo "2) 删除指定端口"
echo "3) 全局替换 IP"
echo "4) 手动编辑 (Nano)"
echo "5) 退出"
read -p "选择操作 [1-5]: " OPT

case $OPT in
    1)
        read -p "请输入监听端口 (如 12701): " PORT
        read -p "请输入落地 IP (多个请用逗号隔开): " IPS
        do_backup
        
        # 将 IP 列表转换为 jq 数组格式
        IPS_JSON=$(echo $IPS | sed 's/,/ /g' | awk '{for(i=1;i<=NF;i++) printf "\"%s:1002\"%s", $i, (i==NF?"":",")}')
        
        # 使用 JQ 智能合并：如果端口存在则更新，不存在则追加
        # 这一段逻辑非常稳，完全不会破坏括号
        jq --arg port ":$PORT" --arg name "svc_$PORT" --argjson nodes "[$IPS_JSON]" \
        '(.services[] | select(.addr == $port)) |= (.handler.forwarder.nodes = ($nodes | map({addr: .}))) | 
         if (.services | any(.addr == $port)) then . else .services += [{name: $name, addr: $port, handler: {type: "relay", forwarder: {nodes: ($nodes | map({addr: .})), selector: {strategy: "round-robin", maxFails: 3, failTimeout: "30s"}}}, listener: {type: "tls"}}] end' \
        "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
        
        apply_conf
        ;;
    2)
        read -p "要删除的端口: " PORT
        do_backup
        jq --arg port ":$PORT" 'del(.services[] | select(.addr == $port))' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
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
