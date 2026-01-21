#!/bin/bash
set -euo pipefail

echo "[INFO] 开始配置 ix 深圳汇聚节点网络优化..."

# ===============================
# 1. 内核参数（针对大流量优化）- 减少清理需求
# ===============================
cat >/etc/sysctl.d/99-ix-core.conf <<'EOF'
# ===== 基础 =====
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1

# ===== conntrack（大幅增加避免频繁清理）=====
net.netfilter.nf_conntrack_max = 6000000
net.netfilter.nf_conntrack_buckets = 1500000
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_generic_timeout = 600

# ===== TCP 连接重用（减少TIME_WAIT）=====
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_fin_timeout = 30

# ===== UDP 优化 =====
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 4194304
net.core.netdev_max_backlog = 500000

# ===== TCP 内存和队列 =====
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_mem = 196608 262144 393216
net.ipv4.tcp_max_syn_backlog = 65536

# ===== BBR 拥塞控制 =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ===== 端口范围 =====
net.ipv4.ip_local_port_range = 20000 65535
net.core.somaxconn = 65535

# ===== 其他优化 =====
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 1800
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# ===== 多路径支持 =====
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_local = 1
net.ipv4.conf.default.accept_local = 1

# ===== IPv6 支持 =====
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOF

# 加载内核模块
modprobe -q nf_conntrack || true
modprobe -q nf_conntrack_ipv4 || true

# 使用 -e 参数忽略不存在的参数错误
sysctl -e -p /etc/sysctl.d/99-ix-core.conf >/dev/null 2>&1 || true

echo "[INFO] 内核参数已加载"

# ===============================
# 2. 安装并优化 unbound（修复版本）
# ===============================
echo "[INFO] 安装和配置 unbound DNS..."

# 安装必要的工具
apt update
apt install -y dnsutils curl wget || true

# 停止并禁用 systemd-resolved
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

# 安装 unbound
if ! command -v unbound &>/dev/null; then
    apt install -y unbound unbound-anchor
fi

# 备份原始配置
cp /etc/unbound/unbound.conf /etc/unbound/unbound.conf.backup 2>/dev/null || true

# 获取 CPU 核心数
CPU_CORES=$(nproc)
THREADS=$((CPU_CORES * 2))
if [ $THREADS -gt 8 ]; then
    THREADS=8
fi

# 创建简化但稳定的 unbound 配置
cat >/etc/unbound/unbound.conf <<EOF
server:
    # 基本设置
    verbosity: 1
    interface: 0.0.0.0
    interface: ::0
    port: 53
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    
    # 访问控制
    access-control: 0.0.0.0/0 allow
    access-control: ::/0 allow
    
    # 性能设置
    num-threads: ${THREADS}
    so-reuseport: yes
    msg-cache-size: 128m
    rrset-cache-size: 256m
    cache-max-ttl: 86400
    cache-min-ttl: 60
    prefetch: yes
    prefetch-key: yes
    
    # 安全设置
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    
    # 查询设置
    outgoing-range: 8192
    num-queries-per-thread: 4096
    edns-buffer-size: 1232
    max-udp-size: 1232

# 转发到上游DNS
forward-zone:
    name: "."
    forward-addr: 223.5.5.5
    forward-addr: 119.29.29.29
EOF

# 创建 systemd 服务目录
mkdir -p /etc/systemd/system/unbound.service.d/

# 创建简单的 systemd 配置（避免复杂权限问题）
cat >/etc/systemd/system/unbound.service.d/override.conf <<'EOF'
[Service]
# 增加文件描述符限制
LimitNOFILE=65536
# 自动重启
Restart=always
RestartSec=3
# 内存限制
MemoryLimit=512M
EOF

# 修复权限和目录
mkdir -p /var/lib/unbound
chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true

# 重新加载 systemd 并启动服务
systemctl daemon-reload
systemctl enable unbound
systemctl restart unbound

# 等待 unbound 启动
sleep 3

echo "[INFO] unbound DNS 缓存已优化启动"

# ===============================
# 3. 配置系统 DNS
# ===============================
echo "[INFO] 配置系统 DNS 设置..."

# 创建 resolv.conf 备份
cp /etc/resolv.conf /etc/resolv.conf.backup 2>/dev/null || true

# 确保 resolv.conf 可写
chattr -i /etc/resolv.conf 2>/dev/null || true

# 配置 DNS
cat >/etc/resolv.conf <<'EOF'
# ix 网络优化配置
nameserver 127.0.0.1
nameserver 223.5.5.5
nameserver 119.29.29.29
options timeout:2 attempts:3 rotate
EOF

# 锁定文件防止被修改
chattr +i /etc/resolv.conf 2>/dev/null || true

echo "[INFO] 系统 DNS 配置完成"

# ===============================
# 4. 测试 DNS 功能
# ===============================
echo "[INFO] 测试 DNS 功能..."

# 等待 unbound 完全启动
sleep 2

# 测试本地 DNS
echo "测试 127.0.0.1 解析："
if dig @127.0.0.1 baidu.com +short +time=2 +tries=2 2>/dev/null | grep -q "."; then
    echo "✓ 本地 DNS 解析成功"
else
    echo "✗ 本地 DNS 解析失败，尝试重启 unbound..."
    systemctl restart unbound
    sleep 2
    
    # 再次测试
    if dig @127.0.0.1 baidu.com +short +time=2 +tries=2 2>/dev/null | grep -q "."; then
        echo "✓ 重启后本地 DNS 解析成功"
    else
        echo "⚠ 本地 DNS 仍然失败，将使用公共 DNS 作为备选"
        # 修改 resolv.conf 把公共 DNS 放前面
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cat >/etc/resolv.conf <<'EOF'
# ix 网络优化配置（本地DNS故障备用）
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 127.0.0.1
options timeout:1 attempts:2 rotate
EOF
        chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
fi

# 测试公共 DNS
echo "测试公共 DNS 解析："
if dig @223.5.5.5 google.com +short +time=2 +tries=2 2>/dev/null | grep -q "."; then
    echo "✓ 公共 DNS 解析成功"
else
    echo "✗ 公共 DNS 解析失败，检查网络连接"
fi

# ===============================
# 5. 创建智能连接跟踪监控
# ===============================
echo "[INFO] 配置连接跟踪监控..."

cat >/usr/local/bin/monitor-conntrack.sh <<'EOF'
#!/bin/bash
# 智能监控连接跟踪表

LOG_FILE="/var/log/conntrack-monitor.log"
MAX_CONNTRACK=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 6000000)
CURRENT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)

# 获取当前时间
HOUR=$(date +%H)

# 判断是否高峰期
PEAK_HOUR=0
if [ $HOUR -ge 8 ] && [ $HOUR -lt 23 ]; then
    PEAK_HOUR=1
fi

# 记录状态
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 连接数: $CURRENT/$MAX_CONNTRACK, 高峰期: $PEAK_HOUR" >> "$LOG_FILE"

# 如果连接数超过500万，在非高峰期清理
if [ $CURRENT -gt 5000000 ] && [ $PEAK_HOUR -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 执行非高峰期清理" >> "$LOG_FILE"
    # 只清理超时连接
    conntrack -D --timeout 600 2>/dev/null || true
fi
EOF

chmod +x /usr/local/bin/monitor-conntrack.sh

# ===============================
# 6. 创建只读监控脚本
# ===============================
cat >/usr/local/bin/check-network.sh <<'EOF'
#!/bin/bash
# 网络状态检查脚本

echo "=== ix 网络优化状态检查 ==="
echo "检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 1. 检查 unbound 状态
echo "1. DNS 服务状态:"
if systemctl is-active --quiet unbound; then
    echo "   ✓ unbound 运行正常"
    echo "   监听端口:"
    ss -tuln | grep :53 || echo "   未找到53端口监听"
else
    echo "   ✗ unbound 未运行"
fi

# 2. 检查 DNS 解析
echo ""
echo "2. DNS 解析测试:"
echo "   本地解析:"
if dig @127.0.0.1 baidu.com +short +time=1 2>/dev/null | head -1; then
    echo "   ✓ 本地 DNS 正常"
else
    echo "   ✗ 本地 DNS 失败"
fi

echo "   公共解析:"
if dig @223.5.5.5 baidu.com +short +time=1 2>/dev/null | head -1; then
    echo "   ✓ 公共 DNS 正常"
else
    echo "   ✗ 公共 DNS 失败"
fi

# 3. 检查连接跟踪
echo ""
echo "3. 连接跟踪状态:"
CONN_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
CONN_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")
if [ "$CONN_COUNT" != "N/A" ] && [ "$CONN_MAX" != "N/A" ]; then
    PERCENT=$((CONN_COUNT * 100 / CONN_MAX))
    echo "   当前连接: $CONN_COUNT"
    echo "   最大限制: $CONN_MAX"
    echo "   使用率: $PERCENT%"
    
    if [ $PERCENT -gt 80 ]; then
        echo "   ⚠ 连接数较高，建议监控"
    fi
else
    echo "   连接跟踪未启用"
fi

# 4. 系统负载
echo ""
echo "4. 系统状态:"
echo "   负载: $(uptime | awk -F'load average:' '{print $2}')"
echo "   内存: $(free -h | awk 'NR==2{print $3"/"$2}')"
echo "   磁盘: $(df -h / | awk 'NR==2{print $4" 可用"}')"
EOF

chmod +x /usr/local/bin/check-network.sh

# ===============================
# 7. 设置定时任务
# ===============================
# 每30分钟检查一次连接数
(crontab -l 2>/dev/null | grep -v "monitor-conntrack"; echo "*/30 * * * * /usr/local/bin/monitor-conntrack.sh >/dev/null 2>&1") | crontab -

# 每天凌晨3点清理日志
(crontab -l 2>/dev/null | grep -v "clean-logs"; echo "0 3 * * * find /var/log -name 'conntrack-*.log' -mtime +7 -delete 2>/dev/null") | crontab -

# ===============================
# 8. 最终验证和提示
# ===============================
echo ""
echo "--------------------------------------"
echo "[SUCCESS] ix 深圳汇聚节点网络优化完成"
echo "--------------------------------------"
echo ""
echo "✅ 已配置完成:"
echo "   1. 内核参数优化 (conntrack_max=600万)"
echo "   2. Unbound 本地 DNS 缓存"
echo "   3. 智能连接监控"
echo "   4. 系统 DNS 配置"
echo ""
echo "🔍 检查命令:"
echo "   /usr/local/bin/check-network.sh"
echo "   systemctl status unbound"
echo "   dig @127.0.0.1 baidu.com +short"
echo ""
echo "📊 查看连接数:"
echo "   cat /proc/sys/net/netfilter/nf_conntrack_count"
echo ""
echo "🔄 重启服务:"
echo "   systemctl restart unbound  # 重启DNS"
echo ""
echo "⚠ 如果仍有图片加载问题，请检查:"
echo "   1. 服务器带宽是否充足"
echo "   2. 使用命令: ping -c 5 baidu.com"
echo "   3. 使用命令: curl -I https://www.baidu.com"
echo ""
echo "📝 日志文件:"
echo "   /var/log/conntrack-monitor.log"
echo "--------------------------------------"

# 运行一次检查
echo ""
echo "[INFO] 运行最终检查..."
/usr/local/bin/check-network.sh
