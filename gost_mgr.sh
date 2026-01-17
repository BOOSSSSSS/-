#!/bin/bash

# --- 0. 基础配置 ---
CONF_FILE="/etc/gost/gost.json"
BACKUP_DIR="/etc/gost/backups"

# --- 1. 权限与必备组件检查 ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ 错误：请使用 sudo 或 root 运行此脚本！"
    exit 1
fi

# 自动安装 jq (如果缺失)
if ! command -v jq &> /dev/null; then
    echo "正在安装必备组件 jq..."
    apt update && apt install jq -y || yum install jq -y
fi

mkdir -p $BACKUP_DIR
[ -f "$CONF_FILE" ] && chmod 666 "$CONF_FILE"

# --- 2. 强力数据预览 (精准 IP 提取逻辑) ---
clear
echo "=============================="
echo "    Gost 落地配置预览"
echo "=============================="

if [ -s "$CONF_FILE" ]; then
    # 核心逻辑：递归搜索所有 addr 字段，但只抓取符合 IP 格式的内容
    DATA=$(jq -r '
        .services[]? | . as $svc | 
        $svc.addr as $p | 
        ($svc | .. | .addr? | select(. != null and test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))) as $ip |
        "\($p) \t \($ip)"
    ' "$CONF_FILE" 2>/dev/null)

    if [ -z "$DATA" ]; then
        echo "💡 提示：当前配置中未发现有效的落地节点。"
    else
        echo -e "监听端口\t| 落地 IP 列表"
        echo "------------------------------------------"
        # 这里的 awk 负责合并同端口的多个 IP
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
    # 格式化并验证 JSON 语法
    temp=$(mktemp)
    if jq . "$CONF_FILE" > "$temp" 2>/dev/null; then
        mv "$temp" "$CONF_FILE"
        if gost -verify -F "$CONF_FILE" > /dev/null 2>&1; then
            # 自动应用 MTU 优化
            ip link set dev $(ip route get 8.8.8.8 | awk '{print $5; exit}') mtu 1380
            systemctl restart gost
            echo -e "\n✅ 配置已保存并重启成功！"
        else
            echo -e "\n⚠️ Gost 校验失败！请选 4 手动检查端口或协议配置。"
        fi
    else
        echo -e "\n❌ JSON 格式严重错误，操作未保存。请选 4 修复。"
        rm -f "$temp"
    fi
}

# --- 4. 交互菜单 ---
echo "1) 增加/修改负载 (输入端口和落地IP列表)"
echo "2) 删除指定端口配置"
echo "3) 全局替换 IP (新旧替换)"
echo "4) 手动编辑文件 (Nano)"
echo "5) 退出"
read -p "选择操作 [1-5]: " OPT

case $OPT in
    1)
        read -p "请输入监听端口 (如 12701): " PORT
        read -p "请输入落地 IP (多个请用逗号隔开): " IPS
        do_backup
        
        # 补全基础结构
        [ ! -s "$CONF_FILE" ] && echo '{"services": []}' > "$CONF_FILE"
        
        # 将 IP 列表转换为 JSON 对象数组
        IPS_JSON=$(echo $IPS | sed 's/,/ /g' | awk '{for(i=1;i<=NF;i++) printf "{\"name\":\"node_%d\",\"addr\":\"%s:1002\"}%s", i, $i, (i==NF?"":",")}')
        
        # 智能自适应修改逻辑：兼容平级 forwarder 和嵌套 forwarder
        jq --arg port ":$PORT" --arg name "${PORT}_tls" --argjson nodes "[$IPS_JSON]" \
        '(.services[]? | select(.addr == $port)) |= (
            if has("forwarder") then .forwarder.nodes = $nodes
            elif (.handler | has("forwarder")) then .handler.forwarder.nodes = $nodes
            else . + {forwarder: {selector: {strategy: "fifo", maxFails: 1, failTimeout: 600000000000}, nodes: $nodes}} end
        ) | 
        if (.services | any(.addr == $port)) then . 
        else .services += [{name: $name, addr: $port, handler: {type: "relay"}, listener: {type: "tls"}, forwarder: {selector: {strategy: "fifo", maxFails: 1, failTimeout: 600000000000}, nodes: $nodes}}] end' \
        "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
        
        apply_conf
        ;;
    2)
        read -p "请输入要删除的监听端口: " PORT
        do_backup
        jq --arg port ":$PORT" 'del(.services[]? | select(.addr == $port))' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
        apply_conf
        ;;
    3)
        read -p "请输入 [旧IP]: " OLD
        read -p "请输入 [新IP]: " NEW
        do_backup
        sed -i "s/$OLD/$NEW/g" "$CONF_FILE"
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
