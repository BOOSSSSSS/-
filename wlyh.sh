#!/bin/bash
set -e

echo "[INFO] 应用 2C2G NAT 稳态网络优化..."

# ===============================
# 1. 内核参数（严格按 2C2G 设计）
# ===============================
cat >/etc/sysctl.d/99-2c2g-stable.conf <<'EOF'
# ===== 基础 =====
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1

# ===== conntrack（2C2G 安全上限）=====
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60
net.netfilter.nf_conntrack_tcp_timeout_established = 7200

# ===== 网络队列（不激进）=====
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 32768

# ===== socket 缓冲 =====
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# ===== 本机端口 =====
net.ipv4.ip_local_port_range = 10000 65535

# ===== NAT / 多入口 =====
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# ===== TCP 稳态 =====
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1

# ===== 保活（保守）=====
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
EOF

sysctl --system >/dev/null
echo "[OK] 内核参数已加载"

# ===============================
# 2. 安装 unbound（轻量 DNS 缓存）
# ===============================
if ! command -v unbound >/dev/null 2>&1; then
    apt update
    apt install -y unbound
fi

# ===============================
# 3. unbound 稳态配置（2C2G 专用）
# ===============================
cat >/etc/unbound/unbound.conf <<'EOF'
server:
    interface: 127.0.0.1
    access-control: 127.0.0.0/8 allow
    port: 53

    do-ip4: yes
    do-udp: yes
    do-tcp: yes

    # ===== 2C2G 并发模型 =====
    num-threads: 2
    so-reuseport: yes
    outgoing-range: 2048
    num-queries-per-thread: 1024

    # ===== 小缓存，防止抢内存 =====
    msg-cache-size: 64m
    rrset-cache-size: 128m
    cache-min-ttl: 60
    cache-max-ttl: 86400

    # ===== 稳定性 =====
    infra-host-ttl: 60
    infra-lame-ttl: 60
    unwanted-reply-threshold: 100000

    hide-identity: yes
    hide-version: yes

forward-zone:
    name: "."
    forward-addr: 1.1.1.1
    forward-addr: 8.8.8.8
EOF

systemctl enable unbound
systemctl restart unbound
echo "[OK] unbound DNS 已启动"

# ===============================
# 4. 本机 DNS 指向（不锁死）
# ===============================
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    systemctl disable --now systemd-resolved
fi

cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
options timeout:1 attempts:3 rotate
EOF

echo "[OK] DNS 已指向本地缓存"

# ===============================
# 5. 自检提示
# ===============================
echo "--------------------------------------"
echo "[SUCCESS] 2C2G NAT 稳态优化完成"
echo
echo "建议检查："
echo "  sysctl net.netfilter.nf_conntrack_max"
echo "  cat /proc/sys/net/netfilter/nf_conntrack_count"
echo "  dig google.com @127.0.0.1"
echo "--------------------------------------"
