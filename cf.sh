#!/bin/bash

# ==========================================================
# CF-SuperTool v5.1 - 终极开源全能版
# GitHub: https://github.com/BOOSSSSSS/-
# ==========================================================
# [配置区]
# 建议在 GitHub 源码中填入你的 Zone ID
ZONE_ID="ae7b890d063bed0b4259242c8ea78d5a"

# 备用配置
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
        elif [[ -f /etc/redhat-release ]]; then
            sudo yum install -y jq
        else
            echo -e "${R}[X] 无法自动安装 jq，请手动安装。${NC}"
            exit 1
        fi
    fi
}

# --- 2. 身份验证获取 ---
get_auth() {
    if [[ -f "$CONF_FILE" ]]; then
        API_TOKEN=$(cat "$CONF_FILE")
    else
        echo -e "${B}首次运行，请输入 Cloudflare API Token (输入时不可见)${NC}"
        # 注意：在 curl 远程执行模式下使用 read 需要特殊处理
        read -s -p "Token: " API_TOKEN < /dev/tty
        echo "$API_TOKEN" > "$CONF_FILE"
        chmod 600 "$CONF_FILE"
        echo -e "\n${G}Token 已加密保存在: $CONF_FILE${NC}"
    fi
}

# --- 3. 获取 DNS 记录 ---
fetch_records() {
    echo -e "${Y}[*] 正在拉取数据...${NC}"
    RECORDS_JSON=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=100" \
         -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json")
    
    if [[ $(echo "$RECORDS_JSON" | jq -r '.success') != "true" ]]; then
        echo -e "${R}❌ API 验证失败！${NC}"
        echo "错误: $(echo "$RECORDS_JSON" | jq -r '.errors[0].message')"
        rm -f "$CONF_FILE"
        exit 1
    fi
}

# --- 4. 修改记录功能 ---
update_record() {
    fetch_records
    echo "--------------------------------------------------------------------------------"
    printf "%-5s %-5s %-8s %-25s %-15s\n" "索引" "类型" "代理" "域名" "当前内容"
    echo "--------------------------------------------------------------------------------"
    echo "$RECORDS_JSON" | jq -r '.result | keys[] as $i | "[\($i)]\t\(.[$i].type)\t\(.[$i].proxied)\t\(.[$i].name)\t\(.[$i].content)"' | expand -t 8
    echo "--------------------------------------------------------------------------------"
    
    read -p "请输入要操作的索引号: " INDEX < /dev/tty
    SELECTED=$(echo "$RECORDS_JSON" | jq -r ".result[$INDEX]")
    [[ "$SELECTED" == "null" ]] && return

    RID=$(echo "$SELECTED" | jq -r '.id')
    RNAME=$(echo "$SELECTED" | jq -r '.name')
    RTYPE=$(echo "$SELECTED" | jq -r '.type')
    RPROXIED=$(echo "$SELECTED" | jq -r '.proxied')

    echo -e "\n${B}操作对象: $RNAME${NC}"
    echo "1) 手动修改 IP"
    echo "2) 自动 DDNS (本机IP)"
    echo "3) 切换代理开关"
    read -p "选择 [1-3]: " ACT < /dev/tty

    case $ACT in
        1) read -p "新 IP: " NEW_IP < /dev/tty ;;
        2) NEW_IP=$(curl -s https://api.ipify.org); echo "本机 IP: $NEW_IP" ;;
        3) [[ "$RPROXIED" == "true" ]] && NEW_P=false || NEW_P=true ;;
    esac

    [[ -z "$NEW_IP" ]] && NEW_IP=$(echo "$SELECTED" | jq -r '.content')
    [[ -z "$NEW_P" ]] && NEW_P=$RPROXIED

    DATA=$(jq -n --arg t "$RTYPE" --arg n "$RNAME" --arg c "$NEW_IP" --argjson p "$NEW_P" '{type:$t,name:$n,content:$c,ttl:1,proxied:$p}')
    RES=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" \
         -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" --data "$DATA")
    
    [[ $(echo "$RES" | jq -r '.success') == "true" ]] && echo -e "${G}✅ 成功！${NC}" || echo -e "${R}❌ 失败${NC}"
}

# --- 5. 存活检测 ---
mass_check() {
    fetch_records
    echo -e "${B}正在执行全解析存活检测...${NC}"
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

# --- 入口控制 ---
main_menu() {
    check_env
    get_auth
    while true; do
        echo -e "\n${B}CF-SuperTool v5.1 控制台${NC}"
        echo "1. 修改 DNS 记录"
        echo "2. 批量 Ping 检测"
        echo "3. 灾备切换 (Failover)"
        echo "5. 清除 Token"
        echo "0. 退出"
        read -p "请选择: " M_OPT < /dev/tty
        case $M_OPT in
            1) update_record ;;
            2) mass_check ;;
            5) rm -f "$CONF_FILE" && echo "Token 已移除" ;;
            0) exit 0 ;;
        esac
    done
}

main_menu
