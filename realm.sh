#!/bin/bash
set -e
# ====== Nuro REALM 高性能加密隧道一键管理脚本（终极优化版）======
# 优化特性：
# 1. 首次运行交互式向导，快速初始化服务端/客户端
# 2. CA证书拉取服务支持手动指定IP（内网/公网）和端口
# 3. 服务端可生成"客户端一键连接命令"，极大简化客户端部署
# 项目地址: https://github.com/zhboner/realm
# 免责声明：仅供学习与交流，请勿用于非法用途。

WORKDIR="/opt/realm"
mkdir -p $WORKDIR
cd $WORKDIR

REALM_BIN="/usr/local/bin/realm"
CONF_FILE="$WORKDIR/realm.json"
RULES_FILE="$WORKDIR/rules.txt"
ROLE_FILE="$WORKDIR/.realm_role"
INIT_FLAG="$WORKDIR/.realm_inited"
CERT_FILE="$WORKDIR/cert.pem"
KEY_FILE="$WORKDIR/key.pem"
CA_FILE="$WORKDIR/ca.pem"
CA_TOKEN_FILE="$WORKDIR/ca_token.txt"
CA_SERVER_IP_FILE="$WORKDIR/.ca_server_ip"
CA_SERVER_PORT_FILE="$WORKDIR/.ca_server_port"

gen_pw() { tr -dc 'a-zA-Z09' < /dev/urandom | head -c 16; }
gen_token() { tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32; }

install_realm() {
 echo "[*] 自动下载并安装最新 realm 二进制..."
 arch=$(uname -m)
 case "$arch" in
 x86_64|amd64) PKG="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
 aarch64|arm64) PKG="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
 *) echo "暂不支持该架构: $arch"; return 1 ;;
 esac
 VERSION=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep tag_name | cut -d '"' -f4)
 [ -z "$VERSION" ] && { echo "无法获取最新版本号。"; return 1; }
 URL="https://github.com/zhboner/realm/releases/download/$VERSION/$PKG"
 echo "[*] 下载地址: $URL"
 cd /tmp
 rm -rf realm-* realm.tar.gz
 wget -O realm.tar.gz "$URL" || { echo "下载失败！"; return 1; }
 tar -xzvf realm.tar.gz || { echo "解压失败！"; return 1; }
 BIN=$(tar -tzf realm.tar.gz | grep '^realm$' || echo realm)
 mv -f $BIN /usr/local/bin/realm
 chmod +x /usr/local/bin/realm
 echo "[√] realm ($VERSION) 已安装/升级到 /usr/local/bin/realm"
 read -p "按回车返回菜单..."
}

generate_cert() {
 openssl req -x509 -newkey rsa:2048 -keyout $KEY_FILE -out $CERT_FILE -days 3650 -nodes -subj "/CN=realm"
 cp $CERT_FILE $CA_FILE
 echo "[√] 证书和私钥已生成"
}

is_inited() { [ -f "$INIT_FLAG" ]; }
detect_role() { [ -f "$ROLE_FILE" ] && cat "$ROLE_FILE" || echo "unknown"; }

init_server() {
 clear
 echo "=== Realm 服务端初始化 ==="
 touch $RULES_FILE
 echo "server" > $ROLE_FILE
 touch $INIT_FLAG
 echo -e "\033[32m服务端基础配置完成。\033[0m"
 read -p "按回车继续..."
}

init_client() {
 clear
 echo "=== Realm 客户端初始化 ==="
 touch $RULES_FILE
 echo "client" > $ROLE_FILE
 touch $INIT_FLAG
 echo -e "\033[36m客户端基础配置完成。\033[0m"
 read -p "按回车继续..."
}

start_ca_server() {
    [ ! -f "$CA_FILE" ] && { echo "未检测到CA证书，请先启用TLS并生成证书！"; sleep 1; return; }
    ! command -v busybox >/dev/null 2>&1 && { apt update -y >/dev/null 2>&1; apt install -y busybox >/dev/null 2>&1; }
    echo "=== 配置 CA 证书拉取服务 ==="
    read -p "请输入用于生成下载链接的IP地址 (直接回车将尝试自动获取): " CUSTOM_IP
    if [ -z "$CUSTOM_IP" ]; then
        CUSTOM_IP=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        [ -z "$CUSTOM_IP" ] && CUSTOM_IP=$(hostname -I | awk '{print $1}')
    fi
    echo "$CUSTOM_IP" > "$CA_SERVER_IP_FILE"
    read -p "请输入CA服务监听端口 [默认: 9001]: " CUSTOM_PORT
    CUSTOM_PORT=${CUSTOM_PORT:-9001}
    echo "$CUSTOM_PORT" > "$CA_SERVER_PORT_FILE"
    [ -f "$CA_TOKEN_FILE" ] || gen_token > "$CA_TOKEN_FILE"
    CA_TOKEN=$(cat "$CA_TOKEN_FILE")
    mkdir -p $WORKDIR/cgi-bin
    cat > $WORKDIR/cgi-bin/ca.cgi <<EOF
#!/bin/sh
echo "Content-type: application/x-pem-file"
echo
if [ "\$(echo \$QUERY_STRING | grep token=$CA_TOKEN)" ]; then
    cat $CA_FILE
else
    echo "Invalid or missing token"
fi
EOF
    chmod +x $WORKDIR/cgi-bin/ca.cgi
    pkill -f "busybox httpd.*-p $CUSTOM_PORT" 2>/dev/null || true
    cd $WORKDIR
    nohup busybox httpd -f -p $CUSTOM_PORT -h . -c cgi-bin > ca_httpd.log 2>&1 &
    echo "[√] CA 拉取服务已启动 (端口: $CUSTOM_PORT)，Token: $CA_TOKEN"
    echo "请使用以下命令下载CA证书:"
    echo "curl \"http://${CUSTOM_IP}:${CUSTOM_PORT}/cgi-bin/ca.cgi?token=${CA_TOKEN}\" -o /opt/realm/ca.pem"
    read -p "按回车返回菜单..."
}

stop_ca_server() {
    if [ -f "$CA_SERVER_PORT_FILE" ]; then
        CA_PORT=$(cat "$CA_SERVER_PORT_FILE")
        pkill -f "busybox httpd.*-p $CA_PORT" 2>/dev/null; RETVAL=$?
    else
        pkill -f "busybox httpd.*-p 9001" 2>/dev/null; RETVAL=$?
    fi
    rm -f $WORKDIR/cgi-bin/ca.cgi
    [ $RETVAL -eq 0 ] && echo "CA 服务已停止！" || echo "未检测到 CA 服务。"
    read -p "按回车返回菜单..."
}

show_ca_token() {
    [ ! -f "$CA_FILE" ] && { echo "未检测到CA证书！"; sleep 1; return; }
    [ ! -f "$CA_TOKEN_FILE" ] && { echo "未生成CA Token！"; sleep 1; return; }
    CA_TOKEN=$(cat "$CA_TOKEN_FILE")
    if [ -f "$CA_SERVER_IP_FILE" ]; then CUSTOM_IP=$(cat "$CA_SERVER_IP_FILE"); else CUSTOM_IP=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'); [ -z "$CUSTOM_IP" ] && CUSTOM_IP=$(hostname -I | awk '{print $1}'); fi
    if [ -f "$CA_SERVER_PORT_FILE" ]; then CUSTOM_PORT=$(cat "$CA_SERVER_PORT_FILE"); else CUSTOM_PORT=9001; fi
    echo "当前CA证书下载命令:"
    echo "curl \"http://${CUSTOM_IP}:${CUSTOM_PORT}/cgi-bin/ca.cgi?token=${CA_TOKEN}\" -o /opt/realm/ca.pem"
    read -p "按回车返回菜单..."
}

# ========== 核心优化：生成客户端一键连接命令 ==========
generate_client_command() {
    is_inited || { echo -e "\e[31m服务端未初始化！\e[0m"; sleep 2; return; }
    [ "$(detect_role)" != "server" ] && { echo "此功能仅限服务端使用。"; sleep 2; return; }
    [ ! -s "$RULES_FILE" ] && { echo -e "\e[31m没有可用的转发规则。\e[0m"; sleep 2; return; }
    [ ! -f "$CA_FILE" ] && { echo -e "\e[33m未找到CA证书。请先启用TLS。\e[0m"; sleep 2; return; }
    [ ! -f "$CA_TOKEN_FILE" ] && { echo -e "\e[33m未找到CA Token。请先启动CA服务。\e[0m"; sleep 2; return; }

    CA_TOKEN=$(cat "$CA_TOKEN_FILE")
    if [ -f "$CA_SERVER_IP_FILE" ]; then
        CA_IP=$(cat "$CA_SERVER_IP_FILE")
    else
        CA_IP=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        [ -z "$CA_IP" ] && CA_IP=$(hostname -I | awk '{print $1}')
    fi
    if [ -f "$CA_SERVER_PORT_FILE" ]; then
        CA_PORT=$(cat "$CA_SERVER_PORT_FILE")
    else
        CA_PORT=9001
    fi
    CA_URL="http://${CA_IP}:${CA_PORT}/cgi-bin/ca.cgi?token=${CA_TOKEN}"

    echo -e "\n\033[32m=== 生成客户端一键连接命令 ===\033[0m"
    echo "请选择转发规则："
    line_num=1
    while read -r LPORT TARGET PW TLS TRANSPORT; do
        [ -z "$TRANSPORT" ] && TRANSPORT="quic"
        echo "  $line_num) 端口: $LPORT, 目标: $TARGET, 密码: $PW, TLS: $TLS, 协议: $TRANSPORT"
        line_num=$((line_num + 1))
    done < "$RULES_FILE"

    read -p "请输入规则序号: " rule_idx
    if ! [[ "$rule_idx" =~ ^[0-9]+$ ]] || [ "$rule_idx" -lt 1 ] || [ "$rule_idx" -gt "$((line_num-1))" ]; then
        echo "无效序号。"; return
    fi
    selected_rule=$(sed -n "${rule_idx}p" "$RULES_FILE")
    read -r LPORT TARGET PW TLS TRANSPORT <<< "$selected_rule"
    [ -z "$TRANSPORT" ] && TRANSPORT="quic"

    echo -e "\n\033[36m[请将以下完整命令复制到客户端服务器执行]\033[0m"
    echo "========================================================================"
    cat <<EOF
sudo bash -c '
WORKDIR="/opt/realm";
mkdir -p \$WORKDIR && cd \$WORKDIR;
echo "正在安装 realm...";
ARCH=\$(uname -m);
[ "\$ARCH" = "x86_64" ] && PKG="realm-x86_64-unknown-linux-gnu.tar.gz";
[ "\$ARCH" = "aarch64" ] && PKG="realm-aarch64-unknown-linux-gnu.tar.gz";
VER=\$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep tag_name | cut -d \\\\" -f4);
curl -L "https://github.com/zhboner/realm/releases/download/\$VER/\$PKG" -o /tmp/realm.tar.gz;
tar -xzf /tmp/realm.tar.gz -C /usr/local/bin/ realm 2>/dev/null;
chmod +x /usr/local/bin/realm 2>/dev/null;
echo "正在拉取CA证书...";
curl -s "$CA_URL" -o \$WORKDIR/ca.pem;
echo "正在写入配置...";
cat > \$WORKDIR/realm.json <<CONFIG
{
  "log": { "level": "info", "output": "stdout" },
  "endpoints": [{
    "listen": "0.0.0.0:$LPORT",
    "remote": "${CA_IP}:${LPORT}",
    "tls": { "enabled": true, "insecure": false, "ca": "\$WORKDIR/ca.pem" },
    "transport": "$TRANSPORT",
    "udp": true,
    "protocol": "shadowsocks",
    "method": "aes-256-gcm",
    "password": "$PW",
    "fast_open": true
  }]
}
CONFIG
echo "正在启动服务...";
pkill -f "realm.*-c \$WORKDIR/realm.json" 2>/dev/null;
nohup /usr/local/bin/realm -c \$WORKDIR/realm.json > \$WORKDIR/realm.log 2>&1 &
echo "✅ 客户端部署完成！";
echo "   - 监听端口: $LPORT";
echo "   - 目标地址: $TARGET";
echo "   - 传输协议: $TRANSPORT";
'
EOF
    echo "========================================================================"
    echo -e "\033[33m注意：请整体复制上方所有行，在客户端终端粘贴执行。\033[0m"
    read -p "按回车返回主菜单..."
}

add_rule() {
 is_inited || { echo -e "\e[31m请先初始化！\e[0m"; sleep 2; return; }
 role=$(detect_role)
 echo "=== 添加端口转发规则 ==="
 echo "1) tcp"; echo "2) quic"; echo "3) ws"
 read -p "选择协议 (默认 quic): " proto_choice
 case "$proto_choice" in 1) TRANSPORT="tcp" ;; 3) TRANSPORT="ws" ;; *) TRANSPORT="quic" ;; esac
 if [[ $role == "server" ]]; then
   read -p "监听端口: " LPORT
   read -p "目标 IP:端口: " TARGET
   read -p "启用 TLS? (y/N): " use_tls
   if [[ "$use_tls" =~ ^[Yy]$ ]]; then [ -f "$CERT_FILE" ] || generate_cert; TLS="true"; else TLS="false"; fi
   PW=$(gen_pw)
   echo "$LPORT $TARGET $PW $TLS $TRANSPORT" >> $RULES_FILE
   echo "已添加: $LPORT --> $TARGET, 密码: $PW, TLS: $TLS, 协议: $TRANSPORT"
 else
   read -p "本地监听端口: " LPORT
   read -p "服务端 IP:端口: " RADDR
   read -p "目标 IP:端口: " TARGET
   read -p "服务器密码: " PW
   read -p "启用 TLS? (y/N): " use_tls
   if [[ "$use_tls" =~ ^[Yy]$ ]]; then
     S_IP=$(echo "$RADDR" | cut -d: -f1)
     CA_FILENAME="ca-${S_IP}.pem"
     echo "请粘贴服务端生成的 curl 命令（整条粘贴）:"
     read -r CA_CURL_CMD
     CA_URL=$(echo "$CA_CURL_CMD" | grep -oP 'http://[0-9\.]+:[0-9]+/cgi-bin/ca\.cgi\?token=[^"]+')
     [ -z "$CA_URL" ] && { echo "命令无效！"; return 1; }
     curl "$CA_URL" -o "$WORKDIR/$CA_FILENAME" || { echo "CA 拉取失败！"; return 1; }
     TLS="true"
   else TLS="false"; CA_FILENAME=""; fi
   echo "$LPORT $RADDR $TARGET $PW $TLS $CA_FILENAME $TRANSPORT" >> $RULES_FILE
   echo "已添加: $LPORT -> $RADDR -> $TARGET, TLS: $TLS, 协议: $TRANSPORT"
 fi
 sleep 1; gen_conf
 [[ $role == "server" ]] && restart_server || restart_client
 read -p "按回车返回菜单..."
}

del_rule() {
 is_inited || { echo -e "\e[31m请先初始化！\e[0m"; sleep 2; return; }
 [ ! -s "$RULES_FILE" ] && { echo "没有规则！"; sleep 1; read -p "按回车返回..."; return; }
 echo -e "\n当前端口转发规则："; line_num=1; role=$(detect_role)
 if [[ "$role" == "server" ]]; then
   while read -r LPORT TARGET PW TLS TRANSPORT; do [ -z "$TRANSPORT" ] && TRANSPORT="quic"; echo "#$line_num 端口: $LPORT, 目标: $TARGET, 密码: $PW, TLS: $TLS, 协议: $TRANSPORT"; line_num=$((line_num + 1)); done < "$RULES_FILE"
 else
   while read -r LPORT RADDR TARGET PW TLS CA_FILENAME TRANSPORT; do [ -z "$TRANSPORT" ] && TRANSPORT="quic"; echo "#$line_num 本地: $LPORT, 服务端: $RADDR, 目标: $TARGET, 密码: $PW, TLS: $TLS, 协议: $TRANSPORT"; line_num=$((line_num + 1)); done < "$RULES_FILE"
 fi
 echo; while true; do
   read -p "输入要删除的序号: " IDX
   if [[ "$IDX" =~ ^[0-9]+$ ]] && [ "$IDX" -ge 1 ] && [ "$IDX" -le "$(wc -l < "$RULES_FILE")" ]; then
     sed -i "${IDX}d" "$RULES_FILE"; echo "已删除 #$IDX"; sleep 1; gen_conf
     [[ "$role" == "server" ]] && restart_server || restart_client; break
   else echo "无效序号。"; fi
 done
 read -p "按回车返回菜单..."
}

view_rules() {
 is_inited || { echo -e "\e[31m请先初始化！\e[0m"; sleep 2; return; }
 echo -e "\n\033[36m[当前端口转发规则]\033[0m"
 if [ ! -s "$RULES_FILE" ]; then echo "无规则"; else
   role=$(detect_role); line_num=1
   if [[ "$role" == "server" ]]; then
     while read -r LPORT TARGET PW TLS TRANSPORT; do [ -z "$TRANSPORT" ] && TRANSPORT="quic"; echo "#$line_num 端口: $LPORT, 目标: $TARGET, 密码: $PW, TLS: $TLS, 协议: $TRANSPORT"; line_num=$((line_num + 1)); done < "$RULES_FILE"
   else
     while read -r LPORT RADDR TARGET PW TLS CA_FILENAME TRANSPORT; do [ -z "$TRANSPORT" ] && TRANSPORT="quic"; echo "#$line_num 本地: $LPORT, 服务端: $RADDR, 目标: $TARGET, 密码: $PW, TLS: $TLS, 协议: $TRANSPORT"; line_num=$((line_num + 1)); done < "$RULES_FILE"
   fi
 fi
 echo; read -p "按回车返回菜单..." _
}

show_server_info() {
 echo -e "\n\033[33m[服务端核心信息]\033[0m"
 if [ -s "$RULES_FILE" ]; then
   line_num=1
   while read -r LPORT TARGET PW TLS TRANSPORT; do [ -z "$TRANSPORT" ] && TRANSPORT="quic"; echo "#$line_num 端口: $LPORT, 目标: $TARGET, 密码: $PW, TLS: $TLS, 协议: $TRANSPORT"; line_num=$((line_num + 1)); done < "$RULES_FILE"
   [ -f "$CERT_FILE" ] && echo "TLS 证书: $CERT_FILE"
 else echo "无规则"; fi
 echo; read -p "按回车返回菜单..."
}

server_status() {
 echo -e "\n\033[32m[服务端进程状态]\033[0m"
 if [ ! -s "$RULES_FILE" ]; then echo -e "\033[33m无规则，请先添加！\033[0m"; else
   PID=$(pgrep -f "realm.*-c $CONF_FILE")
   [ -n "$PID" ] && { echo "realm 已运行，PID: $PID"; ss -ntulp | grep realm | grep LISTEN; } || echo "realm 未运行"
 fi
 echo; read -p "按回车返回菜单..."
}

client_status() {
 echo -e "\n\033[32m[客户端进程状态]\033[0m"
 if [ ! -s "$RULES_FILE" ]; then echo -e "\033[33m无规则，请先添加！\033[0m"; else
   PID=$(pgrep -f "realm.*-c $CONF_FILE")
   [ -n "$PID" ] && { echo "realm 已运行，PID: $PID"; ss -ntulp | grep realm | grep LISTEN; } || echo "realm 未运行"
 fi
 echo; read -p "按回车返回菜单..."
}

gen_conf() {
 ROLE=$(detect_role); echo '{ "log": { "level": "info", "output": "stdout" }, "endpoints": [' > $CONF_FILE
 COUNT=$(wc -l < $RULES_FILE); IDX=1
 if [ "$ROLE" = "server" ]; then
   while read -r LPORT TARGET PW TLS TRANSPORT; do [ -z "$TRANSPORT" ] && TRANSPORT="quic"; SEP=","; [ "$IDX" = "$COUNT" ] && SEP=""
     if [ "$TLS" = "true" ]; then
       cat >> $CONF_FILE <<EOF
 { "listen": "0.0.0.0:$LPORT", "remote": "$TARGET", "tls": { "enabled": true, "certificate": "$CERT_FILE", "key": "$KEY_FILE" }, "transport": "$TRANSPORT", "udp": true, "protocol": "shadowsocks", "method": "aes-256-gcm", "password": "$PW" }$SEP
EOF
     else
       cat >> $CONF_FILE <<EOF
 { "listen": "0.0.0.0:$LPORT", "remote": "$TARGET", "tls": { "enabled": false }, "transport": "$TRANSPORT", "udp": true, "protocol": "shadowsocks", "method": "aes-256-gcm", "password": "$PW" }$SEP
EOF
     fi
   IDX=$((IDX+1)); done < $RULES_FILE
 else
   while read -r LPORT RADDR TARGET PW TLS CA_FILENAME TRANSPORT; do [ -z "$TRANSPORT" ] && TRANSPORT="quic"; SEP=","; [ "$IDX" = "$COUNT" ] && SEP=""
     if [ "$TLS" = "true" ]; then
       cat >> $CONF_FILE <<EOF
 { "listen": "0.0.0.0:$LPORT", "remote": "$RADDR", "tls": { "enabled": true, "insecure": false, "ca": "$WORKDIR/$CA_FILENAME" }, "transport": "$TRANSPORT", "udp": true, "protocol": "shadowsocks", "method": "aes-256-gcm", "password": "$PW", "fast_open": true }$SEP
EOF
     else
       cat >> $CONF_FILE <<EOF
 { "listen": "0.0.0.0:$LPORT", "remote": "$RADDR", "tls": { "enabled": false }, "transport": "$TRANSPORT", "udp": true, "protocol": "shadowsocks", "method": "aes-256-gcm", "password": "$PW", "fast_open": true }$SEP
EOF
     fi
   IDX=$((IDX+1)); done < $RULES_FILE
 fi
 echo ']}' >> $CONF_FILE; echo "配置已同步: $CONF_FILE"; sleep 1
}

restart_server() { is_inited || { echo -e "\e[31m请先初始化！\e[0m"; sleep 2; return; }; gen_conf; pkill -f "$REALM_BIN.*-c $CONF_FILE" || true; nohup $REALM_BIN -c $CONF_FILE > $WORKDIR/realm-server.log 2>&1 &; echo "realm 已重启"; }
restart_client() { is_inited || { echo -e "\e[31m请先初始化！\e[0m"; sleep 2; return; }; gen_conf; pkill -f "$REALM_BIN.*-c $CONF_FILE" || true; nohup $REALM_BIN -c $CONF_FILE > $WORKDIR/realm-client.log 2>&1 &; echo "realm 已重启"; }
stop_server() { pkill -f "$REALM_BIN.*-c $CONF_FILE" && echo "服务端已停止" || echo "服务端未运行"; read -p "按回车返回菜单..."; }
stop_client() { pkill -f "$REALM_BIN.*-c $CONF_FILE" && echo "客户端已停止" || echo "客户端未运行"; read -p "按回车返回菜单..."; }
log_server() { tail -n 50 $WORKDIR/realm-server.log || echo "无日志"; read -p "回车返回..."; }
log_client() { tail -n 50 $WORKDIR/realm-client.log || echo "无日志"; read -p "回车返回..."; }

uninstall_realm() { pkill -f "$REALM_BIN.*-c $CONF_FILE" || true; rm -rf $WORKDIR $REALM_BIN; echo "[√] realm 已彻底删除。"; exit 0; }

# ========== 首次运行快速向导 ==========
first_run_wizard() {
    clear
    echo -e "\033[33m[Realm 隧道快速安装向导]\033[0m"
    echo "本向导将引导您完成基础配置。"
    echo ""
    select role in "服务端 (出口)" "客户端 (入口)" "退出"; do
        case $REPLY in
            1)  # 服务端
                echo "server" > $ROLE_FILE
                touch $INIT_FLAG
                touch $RULES_FILE
                echo "[*] 角色已设置为: 服务端"
                read -p "是否为服务端生成TLS证书？(推荐) (y/N): " gen_cert
                if [[ "$gen_cert" =~ ^[Yy]$ ]]; then
                    generate_cert
                    read -p "是否启动CA证书拉取服务？(客户端需从此拉取CA) (y/N): " start_ca
                    if [[ "$start_ca" =~ ^[Yy]$ ]]; then
                        start_ca_server
                    fi
                fi
                read -p "是否现在添加第一条端口转发规则？(y/N): " add_first_rule
                if [[ "$add_first_rule" =~ ^[Yy]$ ]]; then
                    add_rule
                else
                    echo "您可以在主菜单中随时添加规则。"
                fi
                server_menu
                ;;
            2)  # 客户端
                echo "client" > $ROLE_FILE
                touch $INIT_FLAG
                touch $RULES_FILE
                echo "[*] 角色已设置为: 客户端"
                echo -e "\033[36m[提示]\033[0m 请从服务端管理员处获取'客户端一键连接命令'，并在本机运行。"
                read -p "按回车进入客户端主菜单..."
                client_menu
                ;;
            3)  # 退出
                echo "退出向导。"; exit 0 ;;
            *) echo "无效选择。" ;;
        esac
    done
}

select_role() {
 clear
 echo -e "\033[33m[未检测到已初始化的 realm 服务端或客户端]\033[0m"
 echo "请选择本机角色："
 echo "1) realm 服务端 (出口)"
 echo "2) realm 客户端 (入口)"
 read -p "输入 1 或 2 并回车: " role
 case $role in
 1) echo "server" > $ROLE_FILE ;;
 2) echo "client" > $ROLE_FILE ;;
 *) echo "输入无效，退出"; exit 1 ;;
 esac
}

server_menu() {
 while true; do
 clear
 echo -e "\033[32m==== Realm 隧道服务端菜单 (终极优化版) ====\033[0m"
 echo "1) 一键安装/升级 realm"
 echo "2) 初始化配置并启动"
 echo "3) 添加端口转发规则"
 echo "4) 删除端口转发规则"
 echo "5) 查看所有端口规则"
 echo "6) 重启 realm"
 echo "7) 停止 realm"
 echo "8) 查看服务端日志"
 echo "9) 查看当前转发规则与密码"
 echo "10) 查看当前运行状态"
 echo "11) 启动 CA 拉取服务 (可指定IP/端口)"
 echo "12) 停止 CA 拉取服务"
 echo "13) 查看/复制 CA 拉取 Token 与命令"
 echo "14) 生成客户端一键连接命令 (核心优化)"
 echo "15) 卸载 realm"
 echo "0) 退出"
 echo "-----------------------------"
 read -p "请选择 [0-15]: " choice
 case $choice in
 1) install_realm ;;
 2) init_server ;;
 3) add_rule ;;
 4) del_rule ;;
 5) view_rules ;;
 6) restart_server ;;
 7) stop_server ;;
 8) log_server ;;
 9) show_server_info ;;
 10) server_status ;;
 11) start_ca_server ;;
 12) stop_ca_server ;;
 13) show_ca_token ;;
 14) generate_client_command ;;
 15) uninstall_realm ;;
 0) exit 0 ;;
 *) echo "无效选择，重新输入！" && sleep 1 ;;
 esac
 done
}

client_menu() {
 while true; do
 clear
 echo -e "\033[36m==== Realm 隧道客户端菜单 ====\033[0m"
 echo "1) 一键安装/升级 realm"
 echo "2) 初始化配置并启动"
 echo "3) 添加端口转发规则 (手动)"
 echo "4) 删除端口转发规则"
 echo "5) 查看所有端口规则"
 echo "6) 重启 realm"
 echo "7) 停止 realm"
 echo "8) 查看客户端日志"
 echo "9) 查看当前运行状态"
 echo "10) 卸载 realm"
 echo "0) 退出"
 echo "-----------------------------"
 read -p "请选择 [0-10]: " choice
 case $choice in
 1) install_realm ;;
 2) init_client ;;
 3) add_rule ;;
 4) del_rule ;;
 5) view_rules ;;
 6) restart_client ;;
 7) stop_client ;;
 8) log_client ;;
 9) client_status ;;
 10) uninstall_realm ;;
 0) exit 0 ;;
 *) echo "无效选择，重新输入！" && sleep 1 ;;
 esac
 done
}

# ========== 主程序入口 ==========
# 判断是否为首次运行，是则启动向导，否则进入原有菜单逻辑
if [ ! -f "$INIT_FLAG" ]; then
    first_run_wizard
else
    role="$(detect_role)"
    case "$role" in
    server) server_menu ;;
    client) client_menu ;;
    *)
        select_role
        role2="$(detect_role)"
        [ "$role2" = "server" ] && server_menu
        [ "$role2" = "client" ] && client_menu
        ;;
    esac
fi
