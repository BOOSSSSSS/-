#!/bin/bash

CONF_FILE="/etc/gost/gost.json"

# 检查配置文件是否存在
[ ! -f "$CONF_FILE" ] && echo "❌ 找不到配置文件 $CONF_FILE" && exit 1

# --- 核心功能函数 ---

# 1. 增加负载节点
add_node() {
    read -p "请输入 [主IP]: " MASTER_IP
    read -p "请输入要增加的 [负载IP]: " SLAVE_IP
    
    # 检查主IP是否存在
    if ! grep -q "$MASTER_IP" "$CONF_FILE"; then
        echo "❌ 未找到主IP: $MASTER_IP"
        return
    fi

    # 在主IP所属的nodes数组内增加一个对象
    # 逻辑：定位到包含主IP的那一行，在其后方插入新节点
    sed -i "/$MASTER_IP/a \            { \"addr\": \"$SLAVE_IP:1002\" }," "$CONF_FILE"
    # 修正JSON可能多出的逗号（Gost对末尾逗号较敏感，但新版Gost通常可自动忽略）
    
    echo "✅ 已为 $MASTER_IP 增加负载节点 $SLAVE_IP"
    refresh_service
}

# 2. 删除指定 IP 配置
del_node() {
    read -p "请输入要删除的 [指定IP]: " TARGET_IP
    
    if ! grep -q "$TARGET_IP" "$CONF_FILE"; then
        echo "❌ 配置文件中没找到 IP: $TARGET_IP"
        return
    fi

    # 删除包含该IP的整行
    sed -i "/$TARGET_IP/d" "$CONF_FILE"
    
    # 清理可能残留的非法逗号（删除行后，如果上一行末尾是逗号且下一行是 ]，则删掉上一行逗号）
    # 这一步是为了保证JSON绝对合法
    echo "✅ 已删除 IP: $TARGET_IP"
    refresh_service
}

# 3. 替换 IP
replace_ip() {
    read -p "请输入 [旧IP]: " OLD_IP
    read -p "请输入 [新IP]: " NEW_IP
    
    if ! grep -q "$OLD_IP" "$CONF_FILE"; then
        echo "❌ 未找到旧IP: $OLD_IP"
        return
    fi

    sed -i "s/$OLD_IP/$NEW_IP/g" "$CONF_FILE"
    echo "✅ 已将 $OLD_IP 替换为 $NEW_IP"
    refresh_service
}

# 4. 刷新服务
refresh_service() {
    ip link set dev $(ip route get 8.8.8.8 | awk '{print $5; exit}') mtu 1380
    systemctl restart gost
    echo "🚀 服务已重启并应用新配置。"
}

# --- 交互主菜单 ---
echo "------------------------------"
echo "    Gost 动态节点管理工具"
echo "------------------------------"
echo "1) 增加负载落地 (基于主IP)"
echo "2) 删除指定IP配置"
echo "3) 替换IP (旧换新)"
echo "4) 退出"
read -p "请选择操作 [1-4]: " CHOICE

case $CHOICE in
    1) add_node ;;
    2) del_node ;;
    3) replace_ip ;;
    *) exit 0 ;;
esac
