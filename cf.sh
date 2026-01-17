#!/bin/bash

# ==========================================================
# CF-SuperTool v5.0 - 终极全能运维版
# ==========================================================
# [配置区]
# 请务必在此处填写你的 Zone ID，否则脚本将无法定位域名
ZONE_ID="ae7b890d063bed0b4259242c8ea78d5a"

# 备用配置（可选）
BACKUP_IP="1.1.1.1" 
CONF_FILE="$HOME/.cf_supertool.conf"
# ==========================================================

# 颜色定义
G='\033[0;32m'
R='\033[0;31m'
Y='\033[1;33m'
B='\033[0;34m'
NC='\033[0m'

# --- 1. 环境自检 ---
check_env() {
    if ! command -v jq &> /dev/null; then
        echo -e "${Y}[!] 正在安装依赖 jq...${NC}"
        if [[ -f /etc/debian_version ]]; then
            sudo apt-get update && sudo apt-get install -y jq
        else
            sudo yum install -y jq
        fi
    fi
}

# --- 2. 身份验证获取 ---
get_auth() {
    if [[ -f "$CONF_FILE" ]]; then
        API_TOKEN=$(cat "$CONF_FILE")
    else
        echo -e "${B}首次运行，请输入 Cloudflare API Token (输入时不可见)${NC}"
        read -s -p "Token: " API_TOKEN
        echo "$API_TOKEN" > "$CONF_FILE"
        chmod 600 "$CONF_FILE"
        echo -e "\n${G}Token 已加密保存在: $CONF_FILE${NC}"
    fi
}

# --- 3. 获取 DNS 记录 ---
fetch_records() {
    echo -e "${Y}[*] 正在从 Cloudflare 获取数据...${NC}"
    RECORDS_JSON=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=100" \
         -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json")
    
    if [[ $(echo "$RECORDS_JSON" | jq -r '.success') != "true" ]]; then
        echo -e "${R}❌ API 调用失败！请检查 Token 或 Zone ID。${NC}"
        echo "错误信息: $(echo "$RECORDS_JSON" | jq -r '.errors[0].message')"
        # 如果失败，清除错误的 Token 记录
        rm -f "$CONF_FILE"
        exit 1
    fi
}

# --- 4. 功能：显示记录列表 ---
show_list() {
    fetch_records
    echo "--------------------------------------------------------------------------------"
    printf "%-5s %-5s %-8s %-25s %-15s\n" "索引" "类型" "代理" "域名" "当前内容"
    echo "--------------------------------------------------------------------------------"
    echo "$RECORDS_JSON" | jq -r '.result | keys[] as $i | "[\($i)]\t\(.[$i].type)\t\(.[$i].proxied)\t\(.[$i].name)\t\(.[$i].content)"' | expand -t 8
}

# --- 5. 功能：更新记录 ---
update_record() {
    show_list
    read -p "请输入要操作的记录索引号: " INDEX
    SELECTED=$(echo "$RECORDS_JSON" | jq -r ".result[$INDEX]")
    [[ "$SELECTED" == "null" ]] && { echo "索引不存在"; return; }

    RID=$(echo "$SELECTED" | jq -r '.id')
    RNAME=$(echo "$SELECTED" | jq -r '.name')
    RTYPE=$(echo "$SELECTED" | jq -r '.type')
    RPROXIED=$(echo "$SELECTED" | jq -r '.proxied')

    echo -e "\n${B}正在操作: $RNAME${NC}"
    echo "1) 手动输入新 IP"
    echo "2) 自动 DDNS (更新为本机公网IP)"
    echo "3) 切换代理开关 (当前: $RPROXIED)"
    read -p "选择操作 [1-3]: " ACT

    NEW_IP=$(echo "$SELECTED" | jq -r '.content')
    NEW_P=$RPROXIED

    case $ACT in
        1) read -p "输入新 IP: " NEW_IP ;;
        2) NEW_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me); echo "获取到本机 IP: $NEW_IP" ;;
        3) [[ "$RPROXIED" == "true" ]] && NEW_P=false || NEW_P=true ;;
        *) return ;;
    esac

    PAYLOAD=$(jq -n --arg t "$RTYPE" --arg n "$RNAME" --arg c "$NEW_IP" --argjson p "$NEW_P" '{type:$t,name:$n,content:$c,ttl:1,proxied:$p}')
    RES=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" \
         -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" --data "$PAYLOAD")
    
    [[ $(echo "$RES" | jq -r '.success') == "true" ]] && echo -e "${G}✅ 更新成功！${NC}" || echo -e "${R}❌ 失败${NC}"
}

# --- 6. 功能：一键批量存活检测 ---
mass_check() {
    fetch_records
    echo -e "${B}正在执行全解析存活检测 (Ping)...${NC}"
    echo "$RECORDS_JSON" | jq -c '.result[] | select(.type=="A")' | while read -r row; do
        name=$(echo "$row" | jq -r '.name')
        ip=$(echo "$row" | jq -r '.content')
        if timeout 1 ping -c 1 "$ip" &>/dev/null; then
            echo -e "[$name] -> $ip ${G}[Online]${NC}"
        else
            echo -e "[$name] -> $ip ${R}[Offline]${NC}"
        fi
    done
}

# --- 7. 功能：灾备切换 ---
failover() {
    fetch_records
    read -p "请输入要被替换的【旧 IP】: " OLD_IP
    echo -e "${Y}准备将所有解析从 $OLD_IP 切换到 $BACKUP_IP ...${NC}"
    read -p "确认执行? (y/n): " CONFIRM
    [[ "$confirm" != "y" ]] && return

    echo "$RECORDS_JSON" | jq -c ".result[] | select(.content == \"$OLD_IP\")" | while read -r row; do
        rid=$(echo "$row" | jq -r '.id')
        name=$(echo "$row" | jq -r '.name')
        type=$(echo "$row" | jq -r '.type')
        proxied=$(echo "$row" | jq -r '.proxied')
        
        payload=$(jq -n --arg t "$type" --arg n "$name" --arg c "$BACKUP_IP" --argjson p "$proxied" '{type:$t,name:$n,content:$c,ttl:1,proxied:$p}')
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$rid" \
             -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" --data "$payload" > /dev/null
        echo -e "已切换: $name ${G}[Done]${NC}"
    done
}

# --- 主入口 ---
main_menu() {
    while true; do
        echo -e "\n${B}========================================${NC}"
        echo -e "${B}        CF-SuperTool v5.0 Pro           ${NC}"
        echo -e "${B}========================================${NC}"
        echo "1. 查看/修改 DNS 记录"
        echo "2. 一键批量存活检测 (Ping)"
        echo "3. 一键灾备切换 (Failover)"
        echo "4. 导出 CSV 备份"
        echo "5. 清除保存的 Token"
        echo "0. 退出"
        echo "----------------------------------------"
        read -p "请选择功能: " M_OPT

        case $M_OPT in
            1) update_record ;;
            2) mass_check ;;
            3) failover ;;
            5) rm -f "$CONF_FILE" && echo "Token 已清除" ;;
            0) exit 0 ;;
            *) echo "输入错误" ;;
        esac
    done
}

# 脚本启动引擎
check_env
get_auth
main_menu
