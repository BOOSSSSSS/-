#!/bin/bash

CONF_FILE="/etc/gost/gost.json"
BACKUP_DIR="/etc/gost/backups"

# --- 1. 依赖安装 (只在缺少 jq 时运行) ---
if ! command -v jq &> /dev/null; then
    apt update && apt install jq -y || yum install jq -y
fi
mkdir -p $BACKUP_DIR

# --- 2. 智能读取与数据预览 ---
clear
echo "=============================="
echo "    Gost 落地配置预览"
echo "=============================="

# 智能判断：如果文件存在且 jq 能解析，就展示；否则提示手动检查
if [ -s "$CONF_FILE" ]; then
    # 尝试提取数据，如果报错则不显示预览
    DATA=$(jq -r '.services[]? | .addr as $p | .handler.forwarder.nodes[]?.addr | "\($p) \t \(. )"' "$CONF_FILE" 2>/dev/null)
    
    if [ -z "$DATA" ]; then
        echo "💡 提示：当前配置文件结构较特殊或为空，jq 无法自动解析预览。"
        echo "   (但这不影响你手动运行 Gost，也不会被脚本自动修改)"
    else
        echo -e "监听端口\t| 落地 IP 列表"
        echo "------------------------------------------"
        echo "$DATA" | sed 's/:1002//g; s/://g' | \
        awk '{a[$1]=a[$1] $2 ","} END {for(i in a) {sub(/,$/, "", a[i]); printf "%-15s | %s\n", i, a[i]}}' | sort -n
    fi
else
    echo "🆕 配置文件暂不存在或为空。"
fi
echo "=============================="

# --- 3. 核心工具函数 ---

do_backup() {
    [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "$BACKUP_DIR/gost_$(date +%Y%m%d_%H%M%S).json.bak"
}

apply_conf() {
    # 仅在语法通过时才覆盖原文件
    temp=$(mktemp)
    if jq . "$CONF_FILE" > "$temp" 2>/dev/null; then
        mv "$temp" "$CONF_FILE"
        if gost -verify -F "$CONF_FILE" > /dev/null 2>&1; then
            ip link set dev $(ip route get 8.8.8.8 | awk '{print $5; exit}') mtu 1380
            systemctl restart gost
            echo -e "\n✅ 配置已安全应用并重启！"
        else
            echo -e "\n❌ Gost 校验未通过，请选 4 手动检查语法。"
        fi
    else
        echo -e "\n❌ JQ 解析失败，配置未保存。请检查 JSON 格式。"
        rm -f "$temp"
    fi
}

# --- 4. 交互菜单 ---
echo "1) 增加/修改映射 (输入端口, 自动负载均衡)"
echo "2) 删除指定端口"
echo "3) 全局替换 IP"
echo "4) 手动编辑 (Nano)"
echo "5) 退出"
read -p "选择操作 [1-5]: " OPT

case $OPT in
    1)
        read -p "请输入端口: " PORT
        read -p "请输入落地IP (多个逗号隔开): " IPS
        do_backup
        # 即使文件原来是空的，这一步也会智能创建 services 结构
        [ ! -s "$CONF_FILE" ] && echo '{"services": []}' > "$CONF_FILE"
        
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
        read -p "删除哪个端口: " PORT
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
