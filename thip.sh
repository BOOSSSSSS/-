#!/bin/bash
# GOST配置文件IP管理工具
# 功能：查看和替换IP地址，并显示地理位置信息
# 作者：AI助手
# 日期：2026-01-22

# 配置
CONFIG_DIR="/etc/gost"
BACKUP_DIR="/tmp/gost_backup"
LOG_FILE="/tmp/gost_ip_manager.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'
UNDERLINE='\033[4m'

# 日志函数
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}错误: 缺少必要的依赖:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep"
        done
        echo -e "\n请安装依赖:"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
        echo "  CentOS/RHEL: sudo yum install ${missing_deps[*]}"
        echo "  Alpine: sudo apk add ${missing_deps[*]}"
        exit 1
    fi
}

# 查找配置文件
find_config_files() {
    local config_files=()
    
    if [ -d "$CONFIG_DIR" ]; then
        # 查找所有JSON文件
        while IFS= read -r -d '' file; do
            if [[ "$file" == *.json ]] && [ -f "$file" ]; then
                config_files+=("$file")
            fi
        done < <(find "$CONFIG_DIR" -maxdepth 1 -name "*.json" -print0 2>/dev/null)
    fi
    
    echo "${config_files[@]}"
}

# 显示菜单
show_menu() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              GOST配置文件IP管理工具                       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e ""
    echo -e "${YELLOW}请选择操作:${NC}"
    echo -e "  ${GREEN}1${NC}. 显示当前所有IP地址和地理位置"
    echo -e "  ${GREEN}2${NC}. 替换单个IP地址"
    echo -e "  ${GREEN}3${NC}. 批量替换IP地址"
    echo -e "  ${GREEN}4${NC}. 查找特定服务"
    echo -e "  ${GREEN}5${NC}. 备份当前配置"
    echo -e "  ${GREEN}6${NC}. 还原备份配置"
    echo -e "  ${GREEN}7${NC}. 查看日志"
    echo -e "  ${GREEN}8${NC}. 退出"
    echo -e ""
    echo -n -e "${BLUE}请输入选择 [1-8]: ${NC}"
}

# 查询IP地理位置
get_ip_location() {
    local ip="$1"
    
    # 使用ip-api.com查询
    local response
    response=$(curl -s "http://ip-api.com/json/$ip?fields=status,message,country,countryCode,region,regionName,city,zip,lat,lon,timezone,isp,org,as,query" 2>/dev/null)
    
    if echo "$response" | jq -e '.status == "success"' >/dev/null 2>&1; then
        echo "$response"
    else
        echo '{"status":"fail","message":"查询失败","country":"未知","regionName":"未知","city":"未知","isp":"未知","org":"未知","as":"未知"}'
    fi
}

# 从配置文件中提取IP信息
extract_ip_info() {
    local config_file="$1"
    local ips_file="$2"
    
    # 清空输出文件
    > "$ips_file"
    
    # 使用jq提取所有IP地址和服务信息
    jq -r '.services[] | "\(.name)\t\(.forwarder.nodes[].addr)"' "$config_file" | while IFS=$'\t' read -r service addr; do
        if [[ "$addr" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
            ip="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
            echo "${service}||${ip}||${port}" >> "$ips_file"
        fi
    done
}

# 显示IP信息
display_ip_info() {
    local config_file="$1"
    local temp_ips_file="/tmp/gost_ips_$$.txt"
    local temp_loc_file="/tmp/gost_locations_$$.txt"
    
    echo -e "${CYAN}正在提取IP地址...${NC}"
    extract_ip_info "$config_file" "$temp_ips_file"
    
    local total_ips=$(wc -l < "$temp_ips_file")
    if [ "$total_ips" -eq 0 ]; then
        echo -e "${RED}没有找到IP地址${NC}"
        rm -f "$temp_ips_file" "$temp_loc_file"
        return
    fi
    
    echo -e "${GREEN}找到 $total_ips 个IP地址${NC}"
    echo -e ""
    echo -e "${YELLOW}序号 | 服务名称               | IP地址:端口       | 地理位置${NC}"
    echo -e "${YELLOW}----|------------------------|------------------|-------------------------------${NC}"
    
    local index=1
    while IFS='||' read -r service ip port; do
        # 查询地理位置
        local location_data
        location_data=$(get_ip_location "$ip")
        
        local country city isp
        country=$(echo "$location_data" | jq -r '.country // "未知"')
        city=$(echo "$location_data" | jq -r '.city // "未知"')
        isp=$(echo "$location_data" | jq -r '.isp // "未知"')
        
        # 格式化输出
        printf "%-4s | %-22s | %-16s | %s/%s (%s)\n" \
            "$index" \
            "${service:0:20}..." \
            "$ip:$port" \
            "$country" \
            "$city" \
            "$isp"
        
        index=$((index + 1))
        sleep 0.5  # 避免API限制
    done < "$temp_ips_file"
    
    echo -e ""
    read -p "按Enter键继续..."
    
    # 清理临时文件
    rm -f "$temp_ips_file" "$temp_loc_file"
}

# 替换单个IP
replace_single_ip() {
    local config_file="$1"
    local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    echo -e "${YELLOW}=== 替换单个IP地址 ===${NC}"
    
    # 显示当前IP
    echo -e "${CYAN}当前配置中的IP地址:${NC}"
    jq -r '.services[] | "\(.name): \(.forwarder.nodes[].addr)"' "$config_file" | while read -r line; do
        echo "  $line"
    done
    
    echo -e ""
    read -p "请输入要替换的IP地址 (例如: 77.111.100.38): " old_ip
    
    if [ -z "$old_ip" ]; then
        echo -e "${RED}错误: IP地址不能为空${NC}"
        return
    fi
    
    # 验证IP格式
    if ! [[ "$old_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}错误: IP地址格式不正确${NC}"
        return
    fi
    
    read -p "请输入新的IP地址: " new_ip
    
    if [ -z "$new_ip" ]; then
        echo -e "${RED}错误: 新的IP地址不能为空${NC}"
        return
    fi
    
    if ! [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}错误: 新的IP地址格式不正确${NC}"
        return
    fi
    
    echo -e ""
    echo -e "${YELLOW}查询新IP的地理位置...${NC}"
    local location_data
    location_data=$(get_ip_location "$new_ip")
    
    local country city isp
    country=$(echo "$location_data" | jq -r '.country // "未知"')
    city=$(echo "$location_data" | jq -r '.city // "未知"')
    isp=$(echo "$location_data" | jq -r '.isp // "未知"')
    
    echo -e "${GREEN}新IP地理位置: $country/$city (运营商: $isp)${NC}"
    
    echo -e ""
    read -p "确定要替换吗? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return
    fi
    
    # 备份原文件
    cp "$config_file" "$backup_file"
    echo -e "${GREEN}已创建备份: $backup_file${NC}"
    
    # 使用jq替换IP
    jq --arg old "$old_ip" --arg new "$new_ip" '
        (.services[].forwarder.nodes[].addr) |= (
            gsub($old + ":"; $new + ":")
        )' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}IP地址替换成功!${NC}"
        echo -e ""
        echo -e "${CYAN}修改摘要:${NC}"
        echo -e "  旧IP: $old_ip"
        echo -e "  新IP: $new_ip"
        echo -e "  地理位置: $country/$city"
        echo -e "  备份文件: $backup_file"
    else
        echo -e "${RED}替换失败! 已恢复备份${NC}"
        cp "$backup_file" "$config_file"
    fi
    
    log "替换IP: $old_ip -> $new_ip (位置: $country/$city)"
    
    echo -e ""
    read -p "按Enter键继续..."
}

# 批量替换IP
batch_replace_ip() {
    local config_file="$1"
    
    echo -e "${YELLOW}=== 批量替换IP地址 ===${NC}"
    echo -e ""
    echo -e "${CYAN}请准备一个CSV文件，格式如下:${NC}"
    echo -e "旧IP,新IP"
    echo -e "77.111.100.38,192.168.1.100"
    echo -e "213.210.5.23,192.168.1.101"
    echo -e "..."
    echo -e ""
    
    read -p "请输入CSV文件路径: " csv_file
    
    if [ ! -f "$csv_file" ]; then
        echo -e "${RED}错误: 文件不存在${NC}"
        return
    fi
    
    # 验证CSV格式
    if ! head -1 "$csv_file" | grep -q "旧IP,新IP"; then
        echo -e "${YELLOW}警告: CSV文件可能没有正确的表头，但会尝试处理${NC}"
    fi
    
    echo -e ""
    echo -e "${CYAN}将要执行以下替换:${NC}"
    local count=0
    while IFS=',' read -r old_ip new_ip; do
        # 跳过表头
        [[ "$old_ip" == "旧IP" ]] && continue
        
        if [[ "$old_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
           [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "  $old_ip -> $new_ip"
            count=$((count + 1))
        fi
    done < "$csv_file"
    
    if [ "$count" -eq 0 ]; then
        echo -e "${RED}错误: 没有找到有效的IP地址对${NC}"
        return
    fi
    
    echo -e ""
    read -p "确定要替换以上 $count 个IP地址吗? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return
    fi
    
    # 创建备份
    local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$config_file" "$backup_file"
    echo -e "${GREEN}已创建备份: $backup_file${NC}"
    
    # 批量替换
    local temp_file="${config_file}.tmp"
    cp "$config_file" "$temp_file"
    
    while IFS=',' read -r old_ip new_ip; do
        [[ "$old_ip" == "旧IP" ]] && continue
        
        if [[ "$old_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
           [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            jq --arg old "$old_ip" --arg new "$new_ip" '
                (.services[].forwarder.nodes[].addr) |= (
                    gsub($old + ":"; $new + ":")
                )' "$temp_file" > "${temp_file}.2" && mv "${temp_file}.2" "$temp_file"
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓${NC} 替换 $old_ip -> $new_ip"
                log "批量替换: $old_ip -> $new_ip"
            else
                echo -e "${RED}✗${NC} 替换 $old_ip 失败"
            fi
        fi
    done < "$csv_file"
    
    mv "$temp_file" "$config_file"
    echo -e ""
    echo -e "${GREEN}批量替换完成!${NC}"
    echo -e "备份文件: $backup_file"
    
    read -p "按Enter键继续..."
}

# 查找特定服务
find_service() {
    local config_file="$1"
    
    echo -e "${YELLOW}=== 查找特定服务 ===${NC}"
    echo -e ""
    read -p "请输入服务名称或关键字: " keyword
    
    if [ -z "$keyword" ]; then
        echo -e "${RED}错误: 关键字不能为空${NC}"
        return
    fi
    
    echo -e ""
    echo -e "${CYAN}查找结果:${NC}"
    
    jq -r --arg kw "$keyword" '
        .services[] | 
        select(.name | contains($kw)) | 
        "服务: \(.name)\n地址: \(.addr)\n节点: \(.forwarder.nodes[].addr)\n"
    ' "$config_file"
    
    echo -e ""
    read -p "按Enter键继续..."
}

# 备份配置
backup_config() {
    local config_file="$1"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi
    
    local backup_file="${BACKUP_DIR}/config_$(date +%Y%m%d_%H%M%S).json"
    cp "$config_file" "$backup_file"
    
    echo -e "${GREEN}备份成功!${NC}"
    echo -e "备份文件: $backup_file"
    echo -e ""
    echo -e "${CYAN}最近的备份:${NC}"
    ls -lt "${BACKUP_DIR}/"*.json 2>/dev/null | head -5 | awk '{print "  " $NF}'
    
    log "创建备份: $backup_file"
    
    read -p "按Enter键继续..."
}

# 还原备份
restore_backup() {
    echo -e "${YELLOW}=== 还原备份配置 ===${NC}"
    echo -e ""
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.json 2>/dev/null)" ]; then
        echo -e "${RED}错误: 没有找到备份文件${NC}"
        return
    fi
    
    echo -e "${CYAN}可用的备份文件:${NC}"
    local backups=()
    local index=1
    
    for file in "${BACKUP_DIR}"/config_*.json; do
        if [ -f "$file" ]; then
            local timestamp=$(basename "$file" | sed 's/config_//;s/.json//')
            local size=$(du -h "$file" | cut -f1)
            printf "  [%2d] %s (大小: %s)\n" "$index" "$timestamp" "$size"
            backups[index]="$file"
            index=$((index + 1))
        fi
    done
    
    echo -e ""
    read -p "请选择要还原的备份编号 (1-$((index-1))): " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$index" ]; then
        echo -e "${RED}错误: 选择无效${NC}"
        return
    fi
    
    local selected_backup="${backups[choice]}"
    echo -e ""
    echo -e "将还原备份: ${selected_backup}"
    echo -e ""
    
    read -p "确定要还原吗? 当前配置将被覆盖! (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return
    fi
    
    # 查找原始配置文件
    local config_files=($(find_config_files))
    if [ ${#config_files[@]} -eq 0 ]; then
        echo -e "${RED}错误: 没有找到原始配置文件${NC}"
        return
    fi
    
    echo -e ""
    echo -e "${CYAN}请选择要还原的配置文件:${NC}"
    for i in "${!config_files[@]}"; do
        printf "  [%2d] %s\n" "$((i+1))" "${config_files[i]}"
    done
    
    read -p "请选择 (1-${#config_files[@]}): " file_choice
    if ! [[ "$file_choice" =~ ^[0-9]+$ ]] || [ "$file_choice" -lt 1 ] || [ "$file_choice" -gt ${#config_files[@]} ]; then
        echo -e "${RED}错误: 选择无效${NC}"
        return
    fi
    
    local target_file="${config_files[file_choice-1]}"
    cp "$selected_backup" "$target_file"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}还原成功!${NC}"
        log "还原备份: $selected_backup -> $target_file"
    else
        echo -e "${RED}还原失败!${NC}"
    fi
    
    read -p "按Enter键继续..."
}

# 查看日志
view_log() {
    echo -e "${YELLOW}=== 操作日志 ===${NC}"
    echo -e ""
    
    if [ -f "$LOG_FILE" ]; then
        if [ -s "$LOG_FILE" ]; then
            tail -50 "$LOG_FILE"
        else
            echo -e "${YELLOW}日志文件为空${NC}"
        fi
    else
        echo -e "${RED}日志文件不存在${NC}"
    fi
    
    echo -e ""
    read -p "按Enter键继续..."
}

# 主函数
main() {
    # 检查依赖
    check_dependencies
    
    # 创建日志目录
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # 查找配置文件
    local config_files=($(find_config_files))
    
    if [ ${#config_files[@]} -eq 0 ]; then
        echo -e "${RED}错误: 在 $CONFIG_DIR 中没有找到配置文件${NC}"
        echo -e "请确保GOST配置文件存在于 $CONFIG_DIR 目录中"
        exit 1
    fi
    
    # 选择配置文件
    if [ ${#config_files[@]} -eq 1 ]; then
        selected_config="${config_files[0]}"
        echo -e "${GREEN}找到配置文件: $selected_config${NC}"
    else
        echo -e "${CYAN}找到多个配置文件:${NC}"
        for i in "${!config_files[@]}"; do
            printf "  [%2d] %s\n" "$((i+1))" "${config_files[i]}"
        done
        
        echo -e ""
        read -p "请选择要操作的配置文件 (1-${#config_files[@]}): " choice
        
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#config_files[@]} ]; then
            echo -e "${RED}错误: 选择无效${NC}"
            exit 1
        fi
        
        selected_config="${config_files[choice-1]}"
    fi
    
    echo -e ""
    echo -e "${GREEN}当前操作文件: ${selected_config}${NC}"
    
    # 主循环
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                display_ip_info "$selected_config"
                ;;
            2)
                replace_single_ip "$selected_config"
                ;;
            3)
                batch_replace_ip "$selected_config"
                ;;
            4)
                find_service "$selected_config"
                ;;
            5)
                backup_config "$selected_config"
                ;;
            6)
                restore_backup
                ;;
            7)
                view_log
                ;;
            8)
                echo -e "${GREEN}感谢使用，再见!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 脚本入口
echo -e "${PURPLE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${PURPLE}             GOST配置文件IP管理工具                          ${NC}"
echo -e "${PURPLE}══════════════════════════════════════════════════════════════${NC}"

# 确保脚本以root权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}警告: 建议使用root权限运行此脚本${NC}"
    echo -e ""
    read -p "按Enter键继续，或Ctrl+C退出..."
fi

# 执行主函数
main
