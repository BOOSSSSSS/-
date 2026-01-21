#!/bin/bash
set -euo pipefail

echo "[INFO] 开始配置 ix 深圳汇聚节点网络优化..."

# ===============================
# 1. 内核参数（针对大流量优化）
# ===============================
cat >/etc/sysctl.d/99-ix-core.conf <<'EOF'
# ===== 基础 =====
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1

# ===== conntrack（核心优化：图片加载问题关键）=====
net.netfilter.nf_conntrack_max = 4000000
net.netfilter.nf_conntrack_buckets = 1000000
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# ===== UDP 优化（DNS/QUIC 关键）=====
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 4194304
net.core.netdev_max_backlog = 500000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# ===== TCP 优化 =====
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_mem = 786432 1048576 1572864
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 2000000

# ===== 端口和队列 =====
net.ipv4.ip_local_port_range = 15000 65535
net.core.somaxconn = 65535
net.ipv4.tcp_abort_on_overflow = 0

# ===== 多路径支持 =====
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_local = 1
net.ipv4.conf.default.accept_local = 1

# ===== BBR 拥塞控制 =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ===== IPv6 支持 =====
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOF

# 如果 conntrack 模块未加载则加载
modprobe -q nf_conntrack || true
modprobe -q nf_conntrack_ipv4 || true
modprobe -q nf_conntrack_ipv6 || true

sysctl -p /etc/sysctl.d/99-ix-core.conf >/dev/null

# ===============================
# 2. 调整 conntrack 哈希表大小（必须重启生效）
# ===============================
echo "262144" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true

echo "[INFO] 内核参数已加载"

# ===============================
# 3. 安装并优化 unbound（高性能 DNS）
# ===============================
if ! command -v unbound &>/dev/null; then
    apt update
    apt install -y unbound unbound-anchor
fi

# 备份原始配置
cp /etc/unbound/unbound.conf /etc/unbound/unbound.conf.backup 2>/dev/null || true

# 获取 CPU 核心数
CPU_CORES=$(nproc)
THREADS=$((CPU_CORES * 2))
if [ $THREADS -gt 16 ]; then
    THREADS=16
fi

cat >/etc/unbound/unbound.conf <<EOF
server:
    # 网络接口
    interface: 0.0.0.0
    interface: ::0
    access-control: 0.0.0.0/0 allow
    access-control: ::/0 allow
    port: 53
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    
    # 性能优化（根据CPU核心数调整）
    num-threads: ${THREADS}
    so-reuseport: yes
    outgoing-range: 16384
    num-queries-per-thread: 8192
    outgoing-num-tcp: 256
    incoming-num-tcp: 256
    so-rcvbuf: 4m
    so-sndbuf: 4m
    msg-buffer-size: 65552
    
    # 内存缓存（根据可用内存调整）
    msg-cache-size: 256m
    rrset-cache-size: 512m
    key-cache-size: 128m
    neg-cache-size: 16m
    cache-max-ttl: 86400
    cache-min-ttl: 300
    infra-cache-numhosts: 50000
    infra-cache-slabs: 8
    key-cache-slabs: 8
    rrset-cache-slabs: 8
    
    # 超时和重试
    timeout: 5000
    jostle-timeout: 2000
    stream-wait-size: 65535
    edns-buffer-size: 1232
    max-udp-size: 1232
    
    # 安全设置
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-algo-downgrade: yes
    use-caps-for-id: yes
    unwanted-reply-threshold: 1000000
    val-clean-additional: yes
    val-permissive-mode: no
    
    # 预取和优化
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 3600
    aggressive-nsec: yes
    
    # 日志（生产环境可以减少）
    verbosity: 1
    log-queries: no
    log-replies: no
    log-local-actions: no
    logfile: "/var/log/unbound/unbound.log"
    use-syslog: no

# 上游 DNS 服务器（优化版）
forward-zone:
    name: "."
    forward-addr: 223.5.5.5        # 阿里DNS（深圳节点快）
    forward-addr: 119.29.29.29     # 腾讯DNS
    forward-addr: 8.8.8.8          # Google DNS（备用）
    forward-addr: 1.1.1.1          # Cloudflare（备用）
    forward-tls-upstream: yes

# 本地域和静态记录（可选）
local-zone: "local." static
local-data: "router.local. IN A 192.168.1.1"
EOF

# 创建日志目录和权限
mkdir -p /var/log/unbound
chown -R unbound:unbound /var/log/unbound

# 优化 systemd 服务配置
cat >/etc/systemd/system/unbound.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitMEMLOCK=infinity
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/unbound /var/log/unbound
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
EOF

systemctl daemon-reload
systemctl enable unbound
systemctl restart unbound

echo "[INFO] unbound DNS 缓存已优化启动"

# ===============================
# 4. 系统 DNS 配置
# ===============================
systemctl disable --now systemd-resolved 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true

cat >/etc/resolv.conf <<'EOF'
# Generated by ix network optimization script
nameserver 127.0.0.1
nameserver 223.5.5.5
options timeout:1 attempts:2 rotate
options edns0 single-request-reopen
EOF

chattr +i /etc/resolv.conf 2>/dev/null || true

# ===============================
# 5. 增加文件描述符限制（应对大量连接）
# ===============================
cat >/etc/security/limits.d/99-network.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile unlimited
root hard nofile unlimited
* soft nproc unlimited
* hard nproc unlimited
* soft memlock unlimited
* hard memlock unlimited
EOF

ulimit -n 1048576

# ===============================
# 6. 网络调度优化（如果有大量 UDP 流量）
# ===============================
# 设置网络队列调度（如果有 tc 工具）
if command -v tc &>/dev/null; then
    # 清理现有规则
    tc qdisc del dev eth0 root 2>/dev/null || true
    # 添加 FQ_CODEL 队列（公平队列 + 延迟控制）
    tc qdisc add dev eth0 root fq_codel limit 10240 flows 65536 quantum 1514 target 5ms interval 100ms noecn 2>/dev/null || true
fi

# ===============================
# 7. 监控脚本（可选）
# ===============================
cat >/usr/local/bin/check-network.sh <<'EOF'
#!/bin/bash
echo "=== 网络状态检查 ==="
echo "1. 连接跟踪统计:"
echo "  当前连接数: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'N/A')"
echo "  最大连接数: $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 'N/A')"
echo ""
echo "2. DNS 缓存状态:"
unbound-control stats | grep -E "(total.num|mem.cache|requestlist)" | head -10
echo ""
echo "3. 网络队列:"
ss -u -a | wc -l | awk '{print "UDP sockets:", $1}'
echo ""
echo "4. 内存使用:"
free -h | awk 'NR==2{print "可用内存: "$4}'
EOF

chmod +x /usr/local/bin/check-network.sh

echo "--------------------------------------"
echo "[SUCCESS] ix 深圳汇聚节点深度优化完成"
echo ""
echo "针对图片加载问题的优化措施："
echo "1. 大幅增加 conntrack 表大小（400万条）"
echo "2. 优化 UDP 缓冲区大小"
echo "3. 使用 BBR 拥塞控制算法"
echo "4. 本地 DNS 缓存线程数优化（${THREADS}线程）"
echo "5. 增加文件描述符限制（1048576）"
echo ""
echo "检查命令："
echo "  /usr/local/bin/check-network.sh"
echo "  dmesg | tail -20 | grep -i conntrack"
echo "  unbound-control stats | grep requestlist"
echo "  netstat -su | grep -E 'packet|drop'"
echo ""
echo "如果仍有问题，检查："
echo "1. 服务器带宽是否足够"
echo "2. 图片服务器是否有地域限制"
echo "3. 使用 tcpdump 检查图片请求是否被丢弃"
echo "--------------------------------------"

# 重启网络服务（可选）
if systemctl is-active --quiet networking; then
    systemctl restart networking 2>/dev/null || true
fi
