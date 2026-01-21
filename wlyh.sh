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
# 2. 安装并优化 unbound
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
    interface: 0.0.0.0
    interface: ::0
    access-control: 0.0.0.0/0 allow
    port: 53
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    
    # 性能优化
    num-threads: ${THREADS}
    so-reuseport: yes
    outgoing-range: 8192
    num-queries-per-thread: 4096
    
    # 缓存
    msg-cache-size: 256m
    rrset-cache-size: 512m
    cache-max-ttl: 86400
    cache-min-ttl: 300
    
    # 安全
    hide-identity: yes
    hide-version: yes
    
forward-zone:
    name: "."
    forward-addr: 223.5.5.5
    forward-addr: 119.29.29.29
    forward-addr: 8.8.8.8
EOF

mkdir -p /etc/systemd/system/unbound.service.d/
cat >/etc/systemd/system/unbound.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
Restart=always
RestartSec=3
EOF

systemctl daemon-reload
systemctl enable unbound
systemctl restart unbound

echo "[INFO] unbound DNS 缓存已优化启动"

# ===============================
# 3. 系统 DNS 配置
# ===============================
systemctl disable --now systemd-resolved 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true

cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
nameserver 223.5.5.5
options timeout:1 attempts:2 rotate
EOF

chattr +i /etc/resolv.conf 2>/dev/null || true

# ===============================
# 4. 创建智能连接跟踪监控
# ===============================
cat >/usr/local/bin/monitor-conntrack.sh <<'EOF'
#!/bin/bash
# 智能监控连接跟踪表，避免粗暴清理导致网络中断

LOG_FILE="/var/log/conntrack-monitor.log"
MAX_CONNTRACK=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 6000000)
WARNING_THRESHOLD=$((MAX_CONNTRACK * 80 / 100))  # 80% 警告
CRITICAL_THRESHOLD=$((MAX_CONNTRACK * 90 / 100)) # 90% 严重警告
CURRENT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)

# 获取当前时间
HOUR=$(date +%H)
WEEKDAY=$(date +%u)  # 1=周一, 7=周日

# 判断是否高峰期（深圳时间 8:00-23:00 为高峰期）
PEAK_HOUR=0
if [ $HOUR -ge 8 ] && [ $HOUR -lt 23 ]; then
    PEAK_HOUR=1
fi

# 记录状态
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 检查当前状态
check_status() {
    echo "=== 连接跟踪状态监控 ==="
    echo "当前连接数: $CURRENT"
    echo "最大限制: $MAX_CONNTRACK"
    echo "使用率: $((CURRENT * 100 / MAX_CONNTRACK))%"
    echo "是否高峰期: $([ $PEAK_HOUR -eq 1 ] && echo "是" || echo "否")"
    echo "星期: $WEEKDAY"
    
    # 检查是否有异常增长
    if [ $CURRENT -gt $CRITICAL_THRESHOLD ]; then
        echo "状态: 🔴 严重 - 连接数超过90%！"
        return 3
    elif [ $CURRENT -gt $WARNING_THRESHOLD ]; then
        echo "状态: 🟡 警告 - 连接数超过80%"
        return 2
    else
        echo "状态: 🟢 正常"
        return 0
    fi
}

# 智能清理策略
smart_cleanup() {
    local reason=$1
    
    log_message "触发智能清理: $reason"
    log_message "清理前: $CURRENT/$MAX_CONNTRACK"
    
    # 策略1: 如果是高峰期，只清理超时连接
    if [ $PEAK_HOUR -eq 1 ]; then
        log_message "高峰期 - 仅清理超时连接"
        # 清理超过12小时的TCP连接
        conntrack -D --proto tcp --state ESTABLISHED --timeout 43200 2>/dev/null || true
        # 清理超过5分钟的UDP连接
        conntrack -D --proto udp --timeout 300 2>/dev/null || true
        log_message "高峰期轻度清理完成"
    else
        # 非高峰期，可以更积极地清理
        log_message "非高峰期 - 执行深度清理"
        # 清理TIME_WAIT状态的TCP连接
        conntrack -D --proto tcp --state TIME_WAIT 2>/dev/null || true
        # 清理CLOSE_WAIT状态的TCP连接
        conntrack -D --proto tcp --state CLOSE_WAIT 2>/dev/null || true
        # 清理所有超时连接
        conntrack -D -s 0.0.0.0/0 -d 0.0.0.0/0 --timeout 600 2>/dev/null || true
        log_message "非高峰期深度清理完成"
    fi
    
    # 更新当前连接数
    CURRENT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    log_message "清理后: $CURRENT/$MAX_CONNTRACK"
    
    # 如果仍然很高，尝试其他方法
    if [ $CURRENT -gt $CRITICAL_THRESHOLD ]; then
        log_message "警告: 清理后连接数仍然过高"
        # 尝试增加conntrack表大小
        if [ $MAX_CONNTRACK -lt 8000000 ]; then
            log_message "尝试增加conntrack_max到8000000"
            echo 8000000 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
        fi
    fi
}

# 主逻辑
main() {
    check_status
    status=$?
    
    case $status in
        3)  # 严重状态
            if [ $PEAK_HOUR -eq 1 ]; then
                log_message "高峰期遇到严重状态，执行紧急但保守的清理"
                smart_cleanup "高峰期紧急清理"
            else
                log_message "非高峰期严重状态，执行深度清理"
                smart_cleanup "非高峰期深度清理"
            fi
            ;;
        2)  # 警告状态
            if [ $PEAK_HOUR -eq 0 ]; then
                # 非高峰期达到警告级别，提前清理
                log_message "非高峰期达到警告级别，预防性清理"
                smart_cleanup "非高峰期预防性清理"
            else
                log_message "高峰期警告状态，记录但不清理"
            fi
            ;;
        *)  # 正常状态
            # 记录日志但不清理
            log_message "状态正常: $CURRENT/$MAX_CONNTRACK"
            ;;
    esac
    
    # 每周日凌晨4点执行深度清理（流量最低时）
    if [ $WEEKDAY -eq 7 ] && [ $HOUR -eq 4 ]; then
        log_message "执行每周深度清理维护"
        # 清理所有超时连接
        conntrack -D --timeout 3600 2>/dev/null || true
        # 重启unbound释放内存
        systemctl restart unbound
        log_message "每周维护完成"
    fi
}

# 执行主函数并输出到日志和终端
main 2>&1 | tee -a "$LOG_FILE"
EOF

chmod +x /usr/local/bin/monitor-conntrack.sh

# ===============================
# 5. 创建只读监控脚本（不清理）
# ===============================
cat >/usr/local/bin/check-conntrack.sh <<'EOF'
#!/bin/bash
# 只读监控，不执行任何清理操作

echo "=== 连接跟踪表状态监控（只读）==="
echo "监控时间: $(date '+%Y-%m-%d %H:%M:%S')"

# 获取conntrack信息
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "未启用")
CURRENT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")

if [ "$CURRENT" != "N/A" ] && [ "$MAX" != "未启用" ]; then
    PERCENT=$((CURRENT * 100 / MAX))
    
    echo "当前连接数: $CURRENT"
    echo "最大连接数: $MAX"
    echo "使用率: $PERCENT%"
    
    # 彩色显示状态
    if [ $PERCENT -gt 90 ]; then
        echo -e "状态: \033[31m🔴 危险 ($PERCENT%)\033[0m"
        echo "建议: 立即检查是否有异常连接或DDoS攻击"
    elif [ $PERCENT -gt 70 ]; then
        echo -e "状态: \033[33m🟡 警告 ($PERCENT%)\033[0m"
        echo "建议: 考虑在非高峰期清理"
    else
        echo -e "状态: \033[32m🟢 正常 ($PERCENT%)\033[0m"
    fi
    
    # 显示连接类型分布
    echo ""
    echo "连接类型分布:"
    if command -v conntrack &>/dev/null; then
        conntrack -L 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | \
        while read count type; do
            echo "  $type: $count"
        done
    fi
else
    echo "连接跟踪表未启用或不可用"
fi

echo ""
echo "系统负载: $(uptime | awk -F'load average:' '{print $2}')"
echo "内存使用: $(free -h | awk 'NR==2{print $3"/"$2}')"
echo ""
echo "最近5条监控日志:"
tail -5 /var/log/conntrack-monitor.log 2>/dev/null || echo "无日志"
EOF

chmod +x /usr/local/bin/check-conntrack.sh

# ===============================
# 6. 设置定时任务
# ===============================
# 创建监控目录
mkdir -p /var/log

# 每10分钟监控一次（但不一定清理）
(crontab -l 2>/dev/null | grep -v "monitor-conntrack"; echo "*/10 * * * * /usr/local/bin/monitor-conntrack.sh >/dev/null 2>&1") | crontab -

# 每小时记录一次状态到日志
(crontab -l 2>/dev/null | grep -v "check-conntrack"; echo "0 * * * * /usr/local/bin/check-conntrack.sh >> /var/log/conntrack-hourly.log 2>&1") | crontab -

echo "--------------------------------------"
echo "[SUCCESS] ix 深圳汇聚节点智能优化完成"
echo ""
echo "核心改进："
echo "1. 大幅增加 conntrack_max 到 600万（减少清理需求）"
echo "2. 智能分时段清理策略："
echo "   - 高峰期（8:00-23:00）：只清理超时连接"
echo "   - 非高峰期：执行深度清理"
echo "   - 每周日4:00：执行维护清理"
echo "3. 移除了已废弃的 tcp_tw_recycle 参数"
echo "4. 添加只读监控脚本，不自动清理"
echo ""
echo "监控命令："
echo "  /usr/local/bin/check-conntrack.sh  # 只读查看状态"
echo "  tail -f /var/log/conntrack-monitor.log  # 查看监控日志"
echo ""
echo "手动清理命令（谨慎使用）："
echo "  # 只清理超时连接（安全）"
echo "  conntrack -D --timeout 600"
echo "  # 清理特定状态的连接"
echo "  conntrack -D --state TIME_WAIT"
echo ""
echo "紧急处理："
echo "  如果网络卡顿，先检查连接数："
echo "    cat /proc/sys/net/netfilter/nf_conntrack_count"
echo "  如果超过500万，在业务低峰期手动清理"
echo "--------------------------------------"

# 初始运行一次监控
/usr/local/bin/monitor-conntrack.sh >/dev/null 2>&1

# ===============================
# 7. 验证配置
# ===============================
echo "[INFO] 验证当前配置..."
echo "1. Unbound 状态: $(systemctl is-active unbound)"
echo "2. 连接跟踪表大小: $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo '未启用')"
echo "3. 当前连接数: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'N/A')"
echo "4. DNS 解析测试: $(dig @127.0.0.1 baidu.com +short 2>/dev/null | head -1 || echo '失败')"
echo "[INFO] 优化完成！建议重启服务器使所有配置生效。"
