#!/bin/bash

# 配置路径
CONFIG_DIR="/etc/gost"
CONFIG_FILE="/etc/gost/gost.json"

# 1. 必须以 root 运行
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 错误：请使用 sudo 运行此脚本"
  exit 1
fi

# 2. 检查并创建目录
if [ ! -d "$CONFIG_DIR" ]; then
  echo "📁 目录 $CONFIG_DIR 不存在，正在创建..."
  mkdir -p "$CONFIG_DIR"
  chmod 755 "$CONFIG_DIR"
fi

# 3. 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
  echo "⚠️ 未找到配置文件 $CONFIG_FILE"
  echo '{"services": []}' > "$CONFIG_FILE"
  echo "✅ 已初始化空白配置文件"
fi

echo "=== Gost 后端负载均衡自动配置 (Shell 版) ==="

# 4. 交互输入
read -p "1. 输入要匹配的旧落地 IP:端口 (如 77.111.100.38:1002): " TARGET_ADDR
read -p "2. 输入要增加的新落地 IP (如 45.145.154.225): " NEW_IP

# 自动处理端口
if [[ $NEW_IP != *":"* ]]; then
  NEW_ADDR="${NEW_IP}:1002"
else
  NEW_ADDR="$NEW_IP"
fi

# 5. 备份原文件
BACKUP_FILE="${CONFIG_FILE}.$(date +%Y%m%d_%H%M%S).bak"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "📦 已备份原配置至: $BACKUP_FILE"

# 6. 使用 sed 进行精准替换逻辑 (核心操作)
# 思路：找到匹配旧 IP 的行，并在其后插入新节点，同时修改策略
# 注意：这里假设了 gost.json 的基本格式规范
sed -i "/\"addr\": \"$TARGET_ADDR\"/a \          { \"name\": \"lb_node_$(echo $NEW_IP | cut -d. -f1)\", \"addr\": \"$NEW_ADDR\" }" "$CONFIG_FILE"
sed -i "s/\"strategy\": \"fifo\"/\"strategy\": \"round\"/g" "$CONFIG_FILE"
sed -i "s/\"failTimeout\": 600000000000/\"failTimeout\": 10000000000/g" "$CONFIG_FILE"

echo "✅ 配置文件已更新"

# 7. 重启服务
echo "🔄 正在重启 Gost 服务..."
systemctl restart gost

if [ $? -eq 0 ]; then
  echo "🚀 成功！负载均衡已生效。"
else
  echo "⚠️ 重启失败，请手动检查 gost 服务状态。"
fi
