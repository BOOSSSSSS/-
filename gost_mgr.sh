#!/bin/bash

CONF_FILE="/etc/gost/gost.json"
BACKUP_DIR="/etc/gost/backups"

# --- 1. 自动安装依赖 ---
if ! command -v jq &> /dev/null; then
    apt update && apt install jq -y || yum install jq -y
fi
mkdir -p $BACKUP_DIR

# --- 2. 强力数据读取 (核心修改：确保你能看到内容) ---
clear
echo "=============================="
echo "    Gost 落地配置预览"
echo "=============================="

if [ -s "$CONF_FILE" ]; then
    # 首先尝试用标准的 jq 读取
    DATA=$(jq -r '.services[]? | .addr as $p | .handler.forwarder.nodes[]?.addr | "\($p) \t \(. )"' "$CONF_FILE" 2>/dev/null)
    
    # 如果 jq 读取失败（格式不规范），切换到强力文本提取模式
    if [ -z "$DATA" ]; then
        echo "📢 [兼容模式] 正在尝试从非标准格式中提取数据..."
        DATA=$(grep -E '"addr":|addr:' "$CONF_FILE" | sed 's/[",]//g' | awk '{print $2}' | paste - - 2>/dev/null)
    fi

    if [ -z "$DATA" ]; then
        echo "❌ 无法读取任何有效配置，请选 4 手动检查文件内容。"
    else
        echo -e "监听端口\t| 落地 IP 列表"
        echo "------------------------------------------"
        # 整理输出：去掉后缀，合并同端口 IP
        echo "$DATA" | sed 's/:1002//g; s/://g' | \
        awk '{a[$1]=a[$1] $2 ","} END {for(i in a) {sub(/,$/, "", a[i]); printf "%-15s | %s\n", i, a[i]}}' | sort -n
    fi
else
    echo "🆕 配置文件为空或不存在。"
fi
echo "=============================="

# --- 3. 核心工具函数 ---
do_backup() {
    [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "$BACKUP_DIR/gost_$(date +%Y%m%d_%H%M%S).json.bak"
}

apply_conf() {
    # 语法预检：先检查 jq 能否解析，再检查 gost 能否运行
    if jq . "$CONF_FILE" > /dev/null 2>&1; then
        if gost -verify -F "$CONF_FILE" > /dev/null 2>&1; then
            ip link set dev $(ip route get 8.8.8.8 | awk '{print $5; exit}') mtu 1380
            systemctl restart gost
            echo -e "\n✅ 配置已保存并重启成功！"
        else
            echo -e "\n⚠️ Gost 校验失败！请检查端口占用或特殊配置。"
        fi
    else
        echo -e "\n❌ JSON 格式严重错误，请选 4 手动修复。"
    fi
}

# --- 4. 操作菜单 ---
echo "1) 增加/修改 (输入端口和落地IP列表)"
echo "2) 删除指定端口配置"
echo "3) 全局替换 IP (旧 IP 换新 IP)"
echo "4) 直接编辑文件 (Nano)"
echo "5) 退出"
read -p "请选择操作 [1-5]: " OPT

case $OPT in
    1)
        read -p "请输入端口 (如 12701): " PORT
        read -p "请输入落地IP (多个用逗号隔开): " IPS
        do_backup
        # 补全基础结构
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
