#!/bin/bash

# 配置路径
CONFIG_FILE="/etc/gost/gost.json"

# 1. 检查权限
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 错误：请使用 sudo 运行此脚本"
  exit 1
fi

# 2. 检查文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ 错误：未找到 $CONFIG_FILE"
  exit 1
fi

echo "=== Gost 负载均衡配置助手 (稳定版) ==="

# 3. 交互输入
read -p "请输入要匹配的旧 IP (例如 77.111.100.38): " OLD_IP
read -p "请输入要增加的新落地 IP (例如 45.145.154.225): " NEW_IP

# 4. 调用 Python 处理逻辑 (利用 Python 的 JSON 处理能力，最稳妥)
# 直接将处理脚本写在 EOF 块中
python3 - <<EOF
import json
import os

path = '$CONFIG_FILE'
target_ip = '$OLD_IP'
new_ip = '$NEW_IP'
new_addr = new_ip + ":1002" if ":" not in new_ip else new_ip

with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)

modified = False
for svc in data.get('services', []):
    nodes = svc.get('forwarder', {}).get('nodes', [])
    # 查找是否有匹配旧 IP 的节点
    if any(target_ip in node.get('addr', '') for node in nodes):
        # 1. 添加新节点 (如果不存在)
        if not any(new_ip in node.get('addr', '') for node in nodes):
            nodes.append({"name": "lb_node_" + new_ip.split('.')[0], "addr": new_addr})
        
        # 2. 修改策略为轮询
        selector = svc['forwarder'].setdefault('selector', {})
        selector['strategy'] = 'round'
        selector['maxFails'] = 3
        selector['failTimeout'] = 10000000000
        modified = True

if modified:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print("✅ JSON 修改完成")
else:
    print("⚠️ 未找到匹配的旧 IP，配置未更改")
EOF

# 5. 根据 Python 的执行结果决定是否重启
if [ $? -eq 0 ]; then
    echo "🔄 正在重启 Gost 服务..."
    systemctl restart gost
    echo "🚀 执行完毕！"
else
    echo "❌ 处理过程中出现错误"
fi
