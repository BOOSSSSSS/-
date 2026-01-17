#!/bin/bash

# --- 0. 基础配置 ---
CONF_FILE="/etc/gost/gost.json"
BACKUP_DIR="/etc/gost/backups"

# --- 1. 权限与依赖检查 ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ 错误：请使用 sudo 或 root 运行此脚本！"
    exit 1
fi

# 自动安装 jq
if ! command -v jq &> /dev/null; then
    echo "正在安装必备组件 jq..."
    apt update && apt install jq -y || yum install jq -y
fi

mkdir -p $BACKUP_DIR
[ -f "$CONF_FILE" ] && chmod 666 "$CONF_FILE"

# --- 2. 数据强力预览 (智能提取) ---
clear
echo "=============================="
echo "    Gost 落地配置预览"
echo "=============================="

if [ -s "$CONF_FILE" ]; then
    # 方案 A: 尝试标准 JQ 提取
    DATA=$(jq -r '.services[]? | .addr as $p | .handler.forwarder.nodes[]?.addr | "\($p) \t \(. )"' "$CONF_FILE" 2>/dev/null)
    
    # 方案 B: 如果 JQ 失败，使用强力正则扫描 (忽略 JSON 结构错误)
    if [ -z "$DATA" ]; then
        DATA=$(grep -E '"addr": *"[^"]+"' "$CONF_FILE" | sed 's/[",]//g; s/addr: //g' | awk '{print $NF}' | paste - - 2>/dev/null)
    fi

    if [ -z "$DATA" ]; then
        echo "💡 提示：未能自动识别配置。可能文件为空或格式非标准。"
    else
        echo -e "监听端口\t| 落地 IP 列表"
        echo "------------------------------------------"
        echo "$DATA" | sed 's/:1002//g; s/://g' | \
        awk '{a[$1]=a[$1] $2 ","} END {for(i in a) {sub(/,$/, "", a[i]); printf "%-15s | %s\n", i, a[i]}}' | sort -n
    fi
else
    echo "🆕 配置文件暂不存在。"
fi
echo "=============================="

# --- 3. 核心功能函数 ---

do_backup() {
    [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "$BACKUP_DIR/gost_$(date +%Y%m%d_%H%M%S).json.bak"
}

apply_conf() {
    # 尝试美化 JSON，这也能修正一些轻微的格式问题
    temp=$(mktemp)
    if jq . "$CONF_FILE" > "$temp" 2>/dev/null; then
        mv "$temp" "$CONF_FILE"
        if gost -verify -F "$CONF_FILE" > /dev/null 2>&1; then
            ip link set dev $(ip route get 8.8.8.8 | awk '{print $5; exit}') mtu 1380
            systemctl restart gost
            echo -e "\n✅ 配置已生效并重启！"
        else
            echo -e "\n⚠️ Gost 校验失败，请选 4 手动检查端口或语法。"
        fi
    else
        echo -e "\n❌ JSON 格式严重错误，操作未应用。请选 4 修复。"
        rm -f "$temp"
    fi
}

# --- 4. 交互菜单 ---
echo "1) 增加/修改负载 (输入端口和落地IP列表)"
echo "2) 删除指定端口"
echo "3) 全局替换 IP (新旧 IP 替换)"
echo "4) 手动编辑文件 (Nano)"
echo "5) 退出"
read -p "选择操作 [1-5]: " OPT

case $OPT in
    1)
        read -p "请输入端口 (如 12701): " PORT
        read -p "请输入落地 IP (多个逗号隔开): " IPS
        do_backup
        # 补全基础结构
        [ ! -s "$CONF_FILE" ] || ! grep -q "services" "$CONF_FILE" && echo '{"services": []}' > "$CONF_FILE"
        
        IPS_JSON=$(echo $IPS | sed 's/,/ /g' | awk '{for(i=1;i<=NF;i++) printf "\"%s:1002\"%s", $i, (i==NF?"":",")}')
        
        jq --arg port ":$PORT" --arg name "svc_$PORT" --argjson nodes "[$IPS_JSON]" \
        'if .services == null then .services = [] else . end |
         if (.services | any(.addr == $port)) 
         then (.services[] | select(.addr == $port)).handler.forwarder.nodes = ($nodes | map({addr: .})) 
         else .services += [{name: $name, addr: $port, handler: {type: "relay", forwarder: {nodes: ($nodes | map({addr: .})), selector: {strategy: "round-robin", maxFails: 3, failTimeout: "30s"}}}, listener: {type: "tls"}}] 
         end' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
        apply_conf
        ;;
    2)
        read -p "请输入要删除的端口: " PORT
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
