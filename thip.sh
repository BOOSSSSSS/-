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
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 国家代码到国旗Emoji映射
declare -A COUNTRY_FLAGS=(
    ["CN"]="🇨🇳" ["US"]="🇺🇸" ["JP"]="🇯🇵" ["GB"]="🇬🇧" ["FR"]="🇫🇷" ["DE"]="🇩🇪"
    ["RU"]="🇷🇺" ["KR"]="🇰🇷" ["IN"]="🇮🇳" ["BR"]="🇧🇷" ["CA"]="🇨🇦" ["AU"]="🇦🇺"
    ["IT"]="🇮🇹" ["ES"]="🇪🇸" ["NL"]="🇳🇱" ["SE"]="🇸🇪" ["CH"]="🇨🇭" ["TW"]="🇨🇳"  # 台湾地区显示中国国旗
    ["HK"]="🇭🇰" ["MO"]="🇲🇴" ["SG"]="🇸🇬" ["MY"]="🇲🇾" ["TH"]="🇹🇭" ["VN"]="🇻🇳"
    ["PH"]="🇵🇭" ["ID"]="🇮🇩" ["SA"]="🇸🇦" ["AE"]="🇦🇪" ["TR"]="🇹🇷" ["IL"]="🇮🇱"
)

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

# 获取国家对应的国旗Emoji
get_country_flag() {
    local country_code="$1"
    local country_name="$2"
    
    # 如果传入了国家代码，直接使用
    if [ -n "$country_code" ] && [ "$country_code" != "null" ] && [ "$country_code" != "N/A" ]; then
        # 特殊处理：台湾地区显示中国国旗
        if [ "$country_code" = "TW" ] || [ "$country_code" = "TWN" ]; then
            echo "🇨🇳"
            return
        fi
        
        # 检查映射表中是否存在
        if [ -n "${COUNTRY_FLAGS[$country_code]}" ]; then
            echo "${COUNTRY_FLAGS[$country_code]}"
            return
        fi
        
        # 尝试使用前两个字母
        local short_code="${country_code:0:2}"
        if [ -n "${COUNTRY_FLAGS[$short_code]}" ]; then
            echo "${COUNTRY_FLAGS[$short_code]}"
            return
        fi
    fi
    
    # 通过国家名称映射
    if [ -n "$country_name" ] && [ "$country_name" != "null" ] && [ "$country_name" != "N/A" ]; then
        case "$country_name" in
            *China*|*中国*|*china*)
                echo "🇨🇳"
                ;;
            *Taiwan*|*台湾*|*taiwan*)
                echo "🇨🇳"  # 台湾地区显示中国国旗
                ;;
            *United States*|*美国*|*USA*|*US*)
                echo "🇺🇸"
                ;;
            *Japan*|*日本*|*japan*)
                echo "🇯🇵"
                ;;
            *Korea*|*韩国*|*korea*)
                echo "🇰🇷"
                ;;
            *Germany*|*德国*|*germany*)
                echo "🇩🇪"
                ;;
            *France*|*法国*|*france*)
                echo "🇫🇷"
                ;;
            *United Kingdom*|*英国*|*UK*|*Britain*)
                echo "🇬🇧"
                ;;
            *Russia*|*俄罗斯*|*russia*)
                echo "🇷🇺"
                ;;
            *)
                echo "🌐"  # 默认地球图标
                ;;
        esac
    else
        echo "🌐"  # 默认地球图标
    fi
}

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

# 查询IP地理位置（增强版，返回国家代码）
get_ip_location() {
    local ip="$1"
    
    # 使用ip-api.com查询（获取更多信息包括国家代码）
    local response
    response=$(curl -s "http://ip-api.com/json/$ip?fields=status,country,countryCode,regionName,city,isp,query" 2>/dev/null || echo "{}")
    
    if echo "$response" | grep -q '"status":"success"'; then
        local country country_code region city isp
        country=$(echo "$response" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        country_code=$(echo "$response" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)
        region=$(echo "$response" | grep -o '"regionName":"[^"]*"' | cut -d'"' -f4)
        city=$(echo "$response" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
        isp=$(echo "$response" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
        
        # 返回国家代码和位置信息的复合字符串
        echo "$country_code|$country/$region/$city ($isp)"
    else
        echo "unknown|未知"
    fi
}

# 获取IP的地理位置分组标识
get_location_group() {
    local location_info="$1"
    local country_code=$(echo "$location_info" | cut -d'|' -f1)
    local location_str=$(echo "$location_info" | cut -d'|' -f2)
    
    # 提取国家名称（去除ISP信息）
    local country=$(echo "$location_str" | cut -d'/' -f1 | cut -d'(' -f1 | sed 's/ $//')
    
    # 如果国家是未知，则使用IP地址前两位作为分组
    if [ "$country" = "未知" ] || [ -z "$country" ]; then
        echo "未知地区"
    else
        echo "$country"
    fi
}

# 显示所有IP，按地区分组
display_all_ips_by_group() {
    echo -e "\n${GREEN}正在提取配置文件中的所有IP地址...${NC}"
    
    # 临时文件存储IP信息
    local temp_file="/tmp/gost_ips_$$.txt"
    > "$temp_file"
    
    # 检查JSON结构
    if ! jq -e '.services' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}错误: 配置文件中缺少services字段${NC}"
        return 1
    fi
    
    # 获取服务数量
    local service_count
    service_count=$(jq '.services | length' "$CONFIG_FILE")
    if [ "$service_count" -eq 0 ]; then
        echo -e "${RED}错误: 配置文件中没有找到服务${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}正在分析配置文件，共发现 $service_count 个服务...${NC}"
    
    # 遍历所有服务
    for ((i=0; i<service_count; i++)); do
        # 获取服务名
        local service_name
        service_name=$(jq -r ".services[$i].name // \"未命名服务-$i\"" "$CONFIG_FILE")
        
        # 检查forwarder和nodes是否存在
        if jq -e ".services[$i].forwarder.nodes" "$CONFIG_FILE" >/dev/null 2>&1; then
            # 获取节点数量
            local node_count
            node_count=$(jq ".services[$i].forwarder.nodes | length" "$CONFIG_FILE")
            
            for ((j=0; j<node_count; j++)); do
                # 获取节点信息
                local node_name node_addr
                node_name=$(jq -r ".services[$i].forwarder.nodes[$j].name // \"node_$((j+1))\"" "$CONFIG_FILE")
                node_addr=$(jq -r ".services[$i].forwarder.nodes[$j].addr" "$CONFIG_FILE")
                
                if [[ "$node_addr" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
                    local ip port
                    ip="${BASH_REMATCH[1]}"
                    port="${BASH_REMATCH[2]}"
                    
                    # 查询地理位置
                    local location_info
                    location_info=$(get_ip_location "$ip")
                    local country_code=$(echo "$location_info" | cut -d'|' -f1)
                    local location_str=$(echo "$location_info" | cut -d'|' -f2)
                    
                    # 获取国旗
                    local flag_emoji
                    flag_emoji=$(get_country_flag "$country_code" "$location_str")
                    
                    # 获取地区分组
                    local location_group
                    location_group=$(get_location_group "$location_info")
                    
                    # 保存到临时文件
                    echo "$location_group|$flag_emoji|$location_str|$service_name|$node_name|$ip|$port" >> "$temp_file"
                fi
            done
        fi
    done
    
    # 获取IP总数
    local total_ips
    total_ips=$(wc -l < "$temp_file" 2>/dev/null || echo "0")
    
    if [ "$total_ips" -eq 0 ]; then
        echo -e "${YELLOW}没有找到IP地址${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    echo -e "${GREEN}共发现 $total_ips 个IP地址，按地区分组如下:${NC}\n"
    
    # 按地区分组统计
    echo -e "${CYAN}地区分组统计:${NC}"
    echo "================================================================"
    printf "%-30s | %-10s | %s\n" "地区" "IP数量" "IP地址"
    echo "================================================================"
    
    # 使用awk进行分组统计
    awk -F'|' '{
        group=$1
        ip=$6
        ip_count[group]++
        if (!(ip in ip_seen[group])) {
            ip_seen[group][ip] = 1
            ip_list[group] = ip_list[group] (ip_list[group] == "" ? "" : ", ") ip
        }
    } 
    END {
        for (group in ip_count) {
            printf "%-30s | %-10s | %s\n", group, ip_count[group], ip_list[group]
        }
    }' "$temp_file" | sort
    
    echo ""
    
    # 显示详细列表
    echo -e "${CYAN}详细IP列表:${NC}"
    echo "=================================================================================================================================="
    printf "%-5s | %-30s | %-2s | %-15s | %-8s | %-20s | %-15s\n" \
        "序号" "地区" "国旗" "IP地址" "端口" "服务名称" "节点名称"
    echo "=================================================================================================================================="
    
    # 按地区分组显示
    local current_group=""
    local group_index=0
    local index=1
    
    # 先按地区排序
    sort -t'|' -k1,1 "$temp_file" | while IFS='|' read -r location_group flag_emoji location_str service_name node_name ip port; do
        # 如果是新的地区组，显示组标题
        if [ "$location_group" != "$current_group" ]; then
            current_group="$location_group"
            group_index=$((group_index + 1))
            echo ""
            echo -e "${PURPLE}第 $group_index 组: $location_group ${NC}"
        fi
        
        # 显示IP信息
        printf "%-5s | %-30s | %-2s | %-15s | %-8s | %-20s | %-15s\n" \
            "[$index]" \
            "$location_group" \
            "$flag_emoji" \
            "$ip" \
            "$port" \
            "${service_name:0:18}" \
            "${node_name:0:13}"
        
        index=$((index + 1))
    done
    
    echo ""
    echo "$temp_file"
}

# 选择IP进行替换（支持按地区组替换）
select_ip_to_replace() {
    echo -e "\n${YELLOW}=== 选择要替换的IP地址 ===${NC}"
    
    # 显示所有IP（按地区分组）
    local temp_file
    temp_file=$(display_all_ips_by_group)
    
    if [ -z "$temp_file" ] || [ ! -s "$temp_file" ]; then
        echo -e "${RED}没有找到可替换的IP地址${NC}"
        return 1
    fi
    
    # 获取总IP数
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
    selected_line=$(sort -t'|' -k1,1 "$temp_file" | sed -n "${choice}p")
    
    local location_group flag_emoji location_str service_name node_name old_ip port
    IFS='|' read -r location_group flag_emoji location_str service_name node_name old_ip port <<< "$selected_line"
    
    # 显示选中的IP信息
    echo -e "\n${GREEN}已选择:${NC}"
    echo -e "  序号: $choice"
    echo -e "  地区: $location_group $flag_emoji"
    echo -e "  位置: $location_str"
    echo -e "  服务: $service_name"
    echo -e "  节点: $node_name"
    echo -e "  IP地址: $old_ip:$port"
    
    # 查找同一地区的其他IP
    echo -e "\n${YELLOW}=== 同一地区($location_group)的其他IP地址 ===${NC}"
    
    # 提取同一地区的所有IP
    local same_region_file="/tmp/gost_same_region_$$.txt"
    grep "^$location_group|" "$temp_file" > "$same_region_file"
    
    local region_ip_count=$(wc -l < "$same_region_file" 2>/dev/null)
    
    if [ "$region_ip_count" -gt 1 ]; then
        echo -e "${YELLOW}发现 $region_ip_count 个相同地区的IP地址:${NC}"
        echo "========================================================================================="
        printf "%-5s | %-2s | %-15s | %-8s | %-20s | %-15s\n" \
            "序号" "国旗" "IP地址" "端口" "服务名称" "节点名称"
        echo "========================================================================================="
        
        local region_index=1
        while IFS='|' read -r group flag loc_str svc_name nd_name ip_addr ip_port; do
            printf "%-5s | %-2s | %-15s | %-8s | %-20s | %-15s\n" \
                "$region_index" \
                "$flag" \
                "$ip_addr" \
                "$ip_port" \
                "${svc_name:0:18}" \
                "${nd_name:0:13}"
            region_index=$((region_index + 1))
        done < "$same_region_file"
        
        echo ""
        
        # 询问是否替换同一地区的所有IP
        read -p "是否替换同一地区($location_group)的所有 $region_ip_count 个IP地址? (y/N): " replace_all
        
        if [[ "$replace_all" =~ ^[Yy]$ ]]; then
            echo -e "\n${YELLOW}您选择了替换同一地区的所有IP地址${NC}"
            replace_same_region_ips "$same_region_file" "$location_group"
            rm -f "$same_region_file" "$temp_file"
            return 0
        else
            echo -e "${YELLOW}将只替换选中的单个IP地址${NC}"
        fi
    else
        echo -e "${YELLOW}该地区只有1个IP地址${NC}"
    fi
    
    # 只替换单个IP
    replace_single_ip "$service_name" "$node_name" "$old_ip" "$port" "$flag_emoji" "$location_str"
    
    # 清理临时文件
    rm -f "$same_region_file" "$temp_file"
    return 0
}

# 替换单个IP
replace_single_ip() {
    local service_name="$1"
    local node_name="$2"
    local old_ip="$3"
    local port="$4"
    local flag_emoji="$5"
    local location_str="$6"
    
    # 输入新IP
    echo ""
    read -p "请输入新的IP地址: " new_ip
    
    # 验证IP格式
    if ! [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}错误: IP地址格式不正确${NC}"
        return 1
    fi
    
    # 显示新IP的地理位置
    echo -e "\n${YELLOW}查询新IP的地理位置...${NC}"
    local new_location_info
    new_location_info=$(get_ip_location "$new_ip")
    local new_country_code new_location_str new_flag_emoji
    new_country_code=$(echo "$new_location_info" | cut -d'|' -f1)
    new_location_str=$(echo "$new_location_info" | cut -d'|' -f2)
    new_flag_emoji=$(get_country_flag "$new_country_code" "$new_location_str")
    
    echo -e "  新位置: $new_flag_emoji $new_location_str"
    
    # 确认替换
    echo ""
    read -p "确定要将 $old_ip 替换为 $new_ip 吗? (y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
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
    local old_addr="${old_ip}:${port}"
    
    # 使用jq替换特定服务的特定节点的IP
    if jq -e --arg service "$service_name" --arg node "$node_name" --arg new_addr "$new_addr" \
        '(.services[] | select(.name==$service) | .forwarder.nodes[] | select(.name==$node) | .addr) = $new_addr' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null; then
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        echo -e "${GREEN}✓ IP地址替换成功!${NC}"
        
        # 记录日志
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 替换IP: $service_name/$node_name: $old_ip($flag_emoji) -> $new_ip($new_flag_emoji)" >> "$LOG_FILE"
        
        # 验证修改
        echo -e "\n${YELLOW}验证修改结果:${NC}"
        local updated_addr
        updated_addr=$(jq -r --arg service "$service_name" \
            '.services[] | select(.name==$service) | .forwarder.nodes[].addr' "$CONFIG_FILE" 2>/dev/null | grep "^$new_ip:")
        
        if [ -n "$updated_addr" ]; then
            echo -e "${GREEN}✓ 验证通过: $updated_addr${NC}"
        else
            echo -e "${RED}✗ 验证失败，正在恢复备份...${NC}"
            cp "$backup_file" "$CONFIG_FILE"
        fi
    else
        echo -e "${RED}✗ 替换失败，使用sed尝试...${NC}"
        
        # 如果jq失败，使用sed替换
        if sed -i "s/\"addr\": \"$old_addr\"/\"addr\": \"$new_addr\"/g" "$CONFIG_FILE"; then
            echo -e "${GREEN}✓ 使用sed替换成功!${NC}"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 替换IP: $service_name/$node_name: $old_ip($flag_emoji) -> $new_ip($new_flag_emoji)" >> "$LOG_FILE"
        else
            echo -e "${RED}✗ 所有替换方法都失败了，正在恢复备份...${NC}"
            cp "$backup_file" "$CONFIG_FILE"
        fi
    fi
    
    echo ""
    read -p "按Enter键继续..."
    return 0
}

# 替换同一地区的所有IP
replace_same_region_ips() {
    local region_file="$1"
    local location_group="$2"
    
    # 输入新IP
    echo ""
    read -p "请输入新的IP地址（将替换该地区所有IP）: " new_ip
    
    # 验证IP格式
    if ! [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}错误: IP地址格式不正确${NC}"
        return 1
    fi
    
    # 显示新IP的地理位置
    echo -e "\n${YELLOW}查询新IP的地理位置...${NC}"
    local new_location_info
    new_location_info=$(get_ip_location "$new_ip")
    local new_country_code new_location_str new_flag_emoji
    new_country_code=$(echo "$new_location_info" | cut -d'|' -f1)
    new_location_str=$(echo "$new_location_info" | cut -d'|' -f2)
    new_flag_emoji=$(get_country_flag "$new_country_code" "$new_location_str")
    
    echo -e "  新位置: $new_flag_emoji $new_location_str"
    
    # 再次确认
    local ip_count=$(wc -l < "$region_file" 2>/dev/null)
    echo -e "\n${RED}警告: 这将替换 $location_group 地区的 $ip_count 个IP地址!${NC}"
    read -p "确定要替换吗? (输入 'yes' 确认): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return 0
    fi
    
    # 创建备份
    local backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$backup_file"
    echo -e "${GREEN}已创建备份: $backup_file${NC}"
    
    # 替换所有IP
    echo -e "\n${YELLOW}正在替换IP地址...${NC}"
    
    local success_count=0
    local fail_count=0
    
    while IFS='|' read -r group flag loc_str service_name node_name old_ip port; do
        echo -e "\n${BLUE}处理: $service_name/$node_name - $old_ip:$port${NC}"
        
        # 构建新旧地址
        local old_addr="${old_ip}:${port}"
        local new_addr="${new_ip}:${port}"
        
        # 使用jq替换
        if jq -e --arg service "$service_name" --arg node "$node_name" --arg new_addr "$new_addr" \
            '(.services[] | select(.name==$service) | .forwarder.nodes[] | select(.name==$node) | .addr) = $new_addr' \
            "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null; then
            mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            echo -e "  ${GREEN}✓ 替换成功${NC}"
            success_count=$((success_count + 1))
        else
            # 如果jq失败，尝试sed
            if sed -i "s/\"addr\": \"$old_addr\"/\"addr\": \"$new_addr\"/g" "$CONFIG_FILE"; then
                echo -e "  ${GREEN}✓ 使用sed替换成功${NC}"
                success_count=$((success_count + 1))
            else
                echo -e "  ${RED}✗ 替换失败${NC}"
                fail_count=$((fail_count + 1))
            fi
        fi
    done < "$region_file"
    
    # 记录日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 批量替换地区: $location_group ($ip_count 个IP) -> $new_ip($new_flag_emoji)" >> "$LOG_FILE"
    
    echo -e "\n${GREEN}替换完成!${NC}"
    echo -e "  成功: $success_count 个"
    echo -e "  失败: $fail_count 个"
    echo -e "  备份文件: $backup_file"
    
    echo ""
    read -p "按Enter键继续..."
    return 0
}

# 显示所有IP（简单列表）
display_all_ips_simple() {
    echo -e "\n${GREEN}正在提取配置文件中的所有IP地址...${NC}"
    
    # 临时文件存储IP信息
    local temp_file="/tmp/gost_ips_simple_$$.txt"
    > "$temp_file"
    
    # 检查JSON结构
    if ! jq -e '.services' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}错误: 配置文件中缺少services字段${NC}"
        return 1
    fi
    
    # 获取服务数量
    local service_count
    service_count=$(jq '.services | length' "$CONFIG_FILE")
    if [ "$service_count" -eq 0 ]; then
        echo -e "${RED}错误: 配置文件中没有找到服务${NC}"
        return 1
    fi
    
    # 遍历所有服务
    for ((i=0; i<service_count; i++)); do
        # 获取服务名
        local service_name
        service_name=$(jq -r ".services[$i].name // \"未命名服务-$i\"" "$CONFIG_FILE")
        
        # 检查forwarder和nodes是否存在
        if jq -e ".services[$i].forwarder.nodes" "$CONFIG_FILE" >/dev/null 2>&1; then
            # 获取节点数量
            local node_count
            node_count=$(jq ".services[$i].forwarder.nodes | length" "$CONFIG_FILE")
            
            for ((j=0; j<node_count; j++)); do
                # 获取节点信息
                local node_name node_addr
                node_name=$(jq -r ".services[$i].forwarder.nodes[$j].name // \"node_$((j+1))\"" "$CONFIG_FILE")
                node_addr=$(jq -r ".services[$i].forwarder.nodes[$j].addr" "$CONFIG_FILE")
                
                if [[ "$node_addr" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
                    local ip port
                    ip="${BASH_REMATCH[1]}"
                    port="${BASH_REMATCH[2]}"
                    
                    # 查询地理位置
                    local location_info
                    location_info=$(get_ip_location "$ip")
                    local country_code=$(echo "$location_info" | cut -d'|' -f1)
                    local location_str=$(echo "$location_info" | cut -d'|' -f2)
                    
                    # 获取国旗
                    local flag_emoji
                    flag_emoji=$(get_country_flag "$country_code" "$location_str")
                    
                    # 保存到临时文件
                    echo "$flag_emoji|$location_str|$service_name|$node_name|$ip|$port" >> "$temp_file"
                fi
            done
        fi
    done
    
    # 获取IP总数
    local total_ips
    total_ips=$(wc -l < "$temp_file" 2>/dev/null || echo "0")
    
    if [ "$total_ips" -eq 0 ]; then
        echo -e "${YELLOW}没有找到IP地址${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    echo -e "${GREEN}共发现 $total_ips 个IP地址${NC}\n"
    
    # 显示表头
    echo "=================================================================================================="
    printf "%-5s | %-2s | %-15s | %-8s | %-30s | %-20s | %-15s\n" \
        "序号" "国旗" "IP地址" "端口" "地理位置" "服务名称" "节点名称"
    echo "=================================================================================================="
    
    # 显示每个IP的信息
    local index=1
    while IFS='|' read -r flag_emoji location_str service_name node_name ip port; do
        printf "%-5s | %-2s | %-15s | %-8s | %-30s | %-20s | %-15s\n" \
            "[$index]" \
            "$flag_emoji" \
            "$ip" \
            "$port" \
            "${location_str:0:28}" \
            "${service_name:0:18}" \
            "${node_name:0:13}"
        
        index=$((index + 1))
    done < "$temp_file"
    
    echo ""
    echo "$temp_file"
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
    echo "  1. 查看所有IP（按地区分组）"
    echo "  2. 查看所有IP（简单列表）"
    echo "  3. 选择并替换IP地址"
    echo "  4. 退出"
    echo ""
    echo "================================================"
    echo -n "请输入选择 [1-4]: "
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
                display_all_ips_by_group > /dev/null
                echo ""
                read -p "按Enter键返回菜单..."
                ;;
            2)
                display_all_ips_simple > /dev/null
                echo ""
                read -p "按Enter键返回菜单..."
                ;;
            3)
                select_ip_to_replace
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
