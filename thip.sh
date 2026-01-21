#!/bin/bash
# GOST IP管理工具 - 修复版
# 功能：查看配置文件中的IP地址和地理位置，支持选择替换

CONFIG_DIR="/etc/gost"
LOG_FILE="/tmp/gost_ip_manager.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 检查jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 需要安装jq工具${NC}"
    echo "安装命令:"
    echo "  Ubuntu/Debian: sudo apt-get install jq"
    echo "  CentOS/RHEL: sudo yum install jq"
    echo "  Alpine: sudo apk add jq"
    exit 1
fi

# 检查curl
if ! command -v curl &> /dev/null; then
    echo -e "${RED}错误: 需要安装curl工具${NC}"
    echo "安装命令:"
    echo "  Ubuntu/Debian: sudo apt-get install curl"
    echo "  CentOS/RHEL: sudo yum install curl"
    echo "  Alpine: sudo apk add curl"
    exit 1
fi

# 查找配置文件
find_config_file() {
    local config_files=()
    
    # 查找所有JSON文件
    for file in "$CONFIG_DIR"/*.json; do
        if [ -f "$file" ]; then
            config_files+=("$file")
        fi
    done
    
    if [ ${#config_files[@]} -eq 0 ]; then
        echo -e "${RED}错误: 在 $CONFIG_DIR 目录中没有找到JSON配置文件${NC}"
        return 1
    fi
    
    # 显示可用的配置文件
    echo -e "${GREEN}找到以下配置文件:${NC}"
    for i in "${!config_files[@]}"; do
        echo "  [$((i+1))] ${config_files[i]}"
    done
    
    # 让用户选择
    if [ ${#config_files[@]} -eq 1 ]; then
        CONFIG_FILE="${config_files[0]}"
        echo -e "${YELLOW}自动选择: $CONFIG_FILE${NC}"
        return 0
    fi
    
    read -p "请选择配置文件编号 (1-${#config_files[@]}): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#config_files[@]} ]; then
        echo -e "${RED}错误: 选择无效${NC}"
        return 1
    fi
    
    CONFIG_FILE="${config_files[$((choice-1))]}"
    return 0
}

# 验证JSON文件
validate_json_file() {
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}错误: 配置文件格式无效，不是有效的JSON${NC}"
        return 1
    fi
    
    if ! jq -e '.services' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}错误: 配置文件中缺少services字段${NC}"
        return 1
    fi
    
    return 0
}

# 查询IP地理位置
get_ip_location() {
    local ip="$1"
    
    # 使用ip-api.com查询
    local response
    response=$(curl -s "http://ip-api.com/json/$ip?fields=status,country,regionName,city,isp" 2>/dev/null || echo "{}")
    
    if echo "$response" | grep -q '"status":"success"'; then
        local country city region isp
        country=$(echo "$response" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        region=$(echo "$response" | grep -o '"regionName":"[^"]*"' | cut -d'"' -f4)
        city=$(echo "$response" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
        isp=$(echo "$response" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
        
        echo "$country/$region/$city ($isp)"
    else
        echo "未知"
    fi
}

# 提取IP信息
extract_ip_info() {
    local config_file="$1"
    local temp_file="/tmp/gost_ips_$$.txt"
    
    # 清空临时文件
    > "$temp_file"
    
    # 检查JSON结构
    if ! jq -e '.services' "$config_file" >/dev/null 2>&1; then
        echo -e "${RED}错误: 配置文件中缺少services字段${NC}"
        return 1
    fi
    
    # 获取服务数量
    local service_count
    service_count=$(jq '.services | length' "$config_file")
    if [ "$service_count" -eq 0 ]; then
        echo -e "${RED}错误: 配置文件中没有找到服务${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}正在分析配置文件，共发现 $service_count 个服务...${NC}"
    
    # 遍历所有服务
    for ((i=0; i<service_count; i++)); do
        # 获取服务名
        local service_name
        service_name=$(jq -r ".services[$i].name // \"未命名服务-$i\"" "$config_file")
        
        # 检查forwarder和nodes是否存在
        if jq -e ".services[$i].forwarder.nodes" "$config_file" >/dev/null 2>&1; then
            # 获取节点数量
            local node_count
            node_count=$(jq ".services[$i].forwarder.nodes | length" "$config_file")
            
            for ((j=0; j<node_count; j++)); do
                # 获取节点信息
                local node_name node_addr
                node_name=$(jq -r ".services[$i].forwarder.nodes[$j].name // \"node_$((j+1))\"" "$config_file")
                node_addr=$(jq -r ".services[$i].forwarder.nodes[$j].addr" "$config_file")
                
                if [[ "$node_addr" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
                    local ip port
                    ip="${BASH_REMATCH[1]}"
                    port="${BASH_REMATCH[2]}"
                    
                    # 保存到临时文件
                    echo "$service_name|$node_name|$ip|$port" >> "$temp_file"
                fi
            done
        fi
    done
    
    echo "$temp_file"
}

# 显示所有IP和地理位置
display_all_ips() {
    echo -e "\n${GREEN}正在提取配置文件中的所有IP地址...${NC}"
    
    # 提取IP信息
    local temp_file
    temp_file=$(extract_ip_info "$CONFIG_FILE")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # 获取IP总数
    local total_ips
    total_ips=$(wc -l < "$temp_file" 2>/dev/null || echo "0")
    
    if [ "$total_ips" -eq 0 ]; then
        echo -e "${YELLOW}没有找到IP地址${NC}"
        rm -f "$temp_file"
        return 0
    fi
    
    echo -e "${GREEN}共发现 $total_ips 个IP地址${NC}\n"
    
    # 显示表头
    printf "%-5s | %-20s | %-15s | %-8s | %-30s\n" "序号" "服务名称" "IP地址" "端口" "地理位置"
    echo "------------------------------------------------------------------------------------------------"
    
    # 显示每个IP的信息
    local index=1
    while IFS='|' read -r service_name node_name ip port; do
        # 查询地理位置
        local location
        location=$(get_ip_location "$ip")
        
        # 显示信息
        printf "%-5s | %-20s | %-15s | %-8s | %-30s\n" \
            "[$index]" \
            "${service_name:0:18}..." \
            "$ip" \
            "$port" \
            "$location"
        
        index=$((index + 1))
    done < "$temp_file"
    
    echo ""
    echo "$temp_file"
}

# 选择IP进行替换
select_ip_to_replace() {
    echo -e "\n${YELLOW}=== 选择要替换的IP地址 ===${NC}"
    
    # 显示所有IP
    local temp_file
    temp_file=$(display_all_ips)
    
    if [ -z "$temp_file" ] || [ ! -s "$temp_file" ]; then
        echo -e "${RED}没有找到可替换的IP地址${NC}"
        return 1
    fi
    
    # 获取IP总数
    local total_ips
    total_ips=$(wc -l < "$temp_file" 2>/dev/null)
    
    # 让用户选择
    echo ""
    read -p "请输入要替换的IP序号 (1-$total_ips)，或输入0返回: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 请输入数字${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    if [ "$choice" -eq 0 ]; then
        echo "操作取消"
        rm -f "$temp_file"
        return 0
    fi
    
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$total_ips" ]; then
        echo -e "${RED}错误: 序号无效，请输入1-$total_ips之间的数字${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    # 获取选中的IP信息
    local selected_line
    selected_line=$(sed -n "${choice}p" "$temp_file")
    
    local service_name node_name old_ip port
    IFS='|' read -r service_name node_name old_ip port <<< "$selected_line"
    
    echo -e "\n${GREEN}已选择:${NC}"
    echo -e "  服务: $service_name"
    echo -e "  节点: $node_name"
    echo -e "  IP地址: $old_ip:$port"
    
    # 显示当前地理位置
    local current_location
    current_location=$(get_ip_location "$old_ip")
    echo -e "  当前位置: $current_location"
    
    # 输入新IP
    echo ""
    read -p "请输入新的IP地址: " new_ip
    
    # 验证IP格式
    if ! [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}错误: IP地址格式不正确${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    # 显示新IP的地理位置
    echo -e "\n${YELLOW}查询新IP的地理位置...${NC}"
    local new_location
    new_location=$(get_ip_location "$new_ip")
    echo -e "  新位置: $new_location"
    
    # 确认替换
    echo ""
    read -p "确定要将 $old_ip 替换为 $new_ip 吗? (y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        rm -f "$temp_file"
        return 0
    fi
    
    # 创建备份
    local backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$backup_file"
    echo -e "${GREEN}已创建备份: $backup_file${NC}"
    
    # 使用sed替换IP
    echo -e "\n${YELLOW}正在替换IP地址...${NC}"
    
    # 构建新的地址
    local new_addr="${new_ip}:${port}"
    
    # 使用jq替换特定服务的特定节点的IP
    if jq -e --arg service "$service_name" --arg node "$node_name" --arg new_addr "$new_addr" \
        '(.services[] | select(.name==$service) | .forwarder.nodes[] | select(.name==$node) | .addr) = $new_addr' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null; then
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        echo -e "${GREEN}✓ IP地址替换成功!${NC}"
        
        # 记录日志
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 替换IP: $service_name/$node_name: $old_ip -> $new_ip (位置: $new_location)" >> "$LOG_FILE"
        
        # 验证修改
        echo -e "\n${YELLOW}验证修改结果:${NC}"
        local updated_addr
        updated_addr=$(jq -r --arg service "$service_name" \
            '.services[] | select(.name==$service) | .forwarder.nodes[].addr' "$CONFIG_FILE" 2>/dev/null)
        
        if [ "$updated_addr" = "$new_addr" ]; then
            echo -e "${GREEN}✓ 验证通过: $updated_addr${NC}"
        else
            echo -e "${RED}✗ 验证失败，正在恢复备份...${NC}"
            cp "$backup_file" "$CONFIG_FILE"
        fi
    else
        echo -e "${RED}✗ 替换失败，使用sed尝试...${NC}"
        
        # 如果jq失败，使用sed替换
        if sed -i "s/\"addr\": \"$old_ip:$port\"/\"addr\": \"$new_ip:$port\"/g" "$CONFIG_FILE"; then
            echo -e "${GREEN}✓ 使用sed替换成功!${NC}"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 替换IP: $service_name/$node_name: $old_ip -> $new_ip (位置: $new_location)" >> "$LOG_FILE"
        else
            echo -e "${RED}✗ 所有替换方法都失败了，正在恢复备份...${NC}"
            cp "$backup_file" "$CONFIG_FILE"
        fi
    fi
    
    # 清理临时文件
    rm -f "$temp_file"
    
    echo ""
    read -p "按Enter键继续..."
    return 0
}

# 主菜单
show_menu() {
    clear
    echo "================================================"
    echo "       GOST配置文件IP管理工具"
    echo "================================================"
    echo ""
    echo "当前配置文件: $CONFIG_FILE"
    echo ""
    echo "请选择操作:"
    echo "  1. 显示所有IP地址和地理位置"
    echo "  2. 选择并替换IP地址"
    echo "  3. 批量替换IP地址"
    echo "  4. 退出"
    echo ""
    echo "================================================"
    echo -n "请输入选择 [1-4]: "
}

# 批量替换IP
batch_replace_ips() {
    echo -e "\n${YELLOW}=== 批量替换IP地址 ===${NC}"
    echo ""
    echo "批量替换格式: 每行一个IP映射，格式为 '旧IP,新IP'"
    echo "例如:"
    echo "  77.111.100.38,192.168.1.100"
    echo "  213.210.5.23,192.168.1.101"
    echo ""
    
    read -p "输入IP映射列表 (输入空行结束):"$'\n' ip_mappings
    
    if [ -z "$ip_mappings" ]; then
        echo -e "${YELLOW}没有输入IP映射，操作取消${NC}"
        return
    fi
    
    # 创建备份
    local backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$backup_file"
    echo -e "${GREEN}已创建备份: $backup_file${NC}"
    
    # 处理每对IP映射
    local count=0
    while IFS=',' read -r old_ip new_ip; do
        # 跳过空行
        [ -z "$old_ip" ] && continue
        [ -z "$new_ip" ] && continue
        
        # 验证IP格式
        if ! [[ "$old_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
           ! [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RED}✗ 跳过无效IP对: $old_ip -> $new_ip${NC}"
            continue
        fi
        
        echo -e "\n${YELLOW}处理: $old_ip -> $new_ip${NC}"
        
        # 查询新IP的地理位置
        local location
        location=$(get_ip_location "$new_ip")
        echo -e "  新位置: $location"
        
        # 替换所有匹配的IP
        if sed -i "s/\"$old_ip:/\"$new_ip:/g" "$CONFIG_FILE"; then
            echo -e "${GREEN}✓ 替换成功${NC}"
            count=$((count + 1))
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 批量替换: $old_ip -> $new_ip" >> "$LOG_FILE"
        else
            echo -e "${RED}✗ 替换失败${NC}"
        fi
    done <<< "$ip_mappings"
    
    echo -e "\n${GREEN}批量替换完成! 共替换了 $count 个IP地址${NC}"
    echo "备份文件: $backup_file"
    
    echo ""
    read -p "按Enter键继续..."
}

# 主函数
main() {
    # 查找配置文件
    if ! find_config_file; then
        exit 1
    fi
    
    # 验证配置文件
    if ! validate_json_file; then
        exit 1
    fi
    
    # 创建日志目录
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # 主循环
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                display_all_ips > /dev/null
                echo ""
                read -p "按Enter键返回菜单..."
                ;;
            2)
                select_ip_to_replace
                ;;
            3)
                batch_replace_ips
                ;;
            4)
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

# 运行主函数
main
