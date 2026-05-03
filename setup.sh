#!/bin/bash
# HTTP Boot Server - 一键部署脚本
# 支持 PXE/UEFI 网络启动，Web 界面上传镜像，HTTPS 加密
# 适用于 RHEL 7/8/9

set -e

# ============================================================================
# 配置变量
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/var/lib/http-boot-server"
BOOT_DIR="${INSTALL_DIR}/boot"
CERT_DIR="${INSTALL_DIR}/certs"
CONFIG_DIR="${INSTALL_DIR}/config"
LOG_DIR="/var/log/http-boot-server"

# 网络配置（可根据实际情况修改）
SERVER_IP=$(hostname -I | awk '{print $1}')
DHCP_RANGE_START="192.168.1.100"
DHCP_RANGE_END="192.168.1.200"
DHCP_SUBNET="192.168.1.0"
DHCP_NETMASK="255.255.255.0"
DHCP_GATEWAY="${SERVER_IP}"
DHCP_DNS="8.8.8.8"

# 服务端口
HTTP_PORT=80
HTTPS_PORT=443
UPLOAD_PORT=8443

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# 工具函数
# ============================================================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}========== $1 ==========${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限运行此脚本: sudo $0"
        exit 1
    fi
}

check_rhel() {
    if [[ ! -f /etc/redhat-release ]]; then
        log_error "此脚本仅适用于 RHEL/CentOS 系统"
        exit 1
    fi

    RHEL_VERSION=$(rpm -E %{rhel})
    log_info "检测到 RHEL 版本: ${RHEL_VERSION}"

    if [[ ${RHEL_VERSION} -lt 7 ]]; then
        log_error "需要 RHEL 7 或更高版本"
        exit 1
    fi
}

detect_network() {
    log_step "检测网络配置"

    # 获取主要网络接口
    DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "${DEFAULT_IF}" ]]; then
        log_error "无法检测默认网络接口"
        exit 1
    fi

    SERVER_IP=$(ip -4 addr show "${DEFAULT_IF}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [[ -z "${SERVER_IP}" ]]; then
        log_error "无法获取服务器 IP 地址"
        exit 1
    fi

    # 获取子网信息
    SUBNET_INFO=$(ip -4 addr show "${DEFAULT_IF}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
    SUBNET_MASK=$(ipcalc -m "${SUBNET_INFO}" 2>/dev/null | cut -d= -f2 || echo "255.255.255.0")
    NETWORK_ADDR=$(ipcalc -n "${SUBNET_INFO}" 2>/dev/null | cut -d= -f2 || echo "192.168.1.0")

    # 自动计算 DHCP 范围
    IFS='.' read -r -a IP_PARTS <<< "${SERVER_IP}"
    DHCP_RANGE_START="${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.100"
    DHCP_RANGE_END="${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.200"
    DHCP_SUBNET="${NETWORK_ADDR}"
    DHCP_NETMASK="${SUBNET_MASK}"
    DHCP_GATEWAY="${SERVER_IP}"

    log_info "网络接口: ${DEFAULT_IF}"
    log_info "服务器 IP: ${SERVER_IP}"
    log_info "子网: ${DHCP_SUBNET}/${DHCP_NETMASK}"
    log_info "DHCP 范围: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
}

# ============================================================================
# 安装依赖
# ============================================================================
install_dependencies() {
    log_step "安装依赖包"

    # 启用 EPEL 仓库（如果需要）
    if ! rpm -q epel-release &>/dev/null; then
        log_info "安装 EPEL 仓库..."
        yum install -y epel-release || dnf install -y epel-release
    fi

    # 安装必要软件包
    PACKAGES=(
        dhcp-server
        tftp-server
        xinetd
        nginx
        python3
        python3-pip
        openssl
        firewalld
        wget
        curl
    )

    for pkg in "${PACKAGES[@]}"; do
        if ! rpm -q "${pkg}" &>/dev/null; then
            log_info "安装 ${pkg}..."
            yum install -y "${pkg}" || dnf install -y "${pkg}"
        else
            log_info "${pkg} 已安装"
        fi
    done

    # 安装 Python Flask
    log_info "安装 Python Flask..."
    pip3 install flask || python3 -m pip install flask

    log_info "依赖包安装完成"
}

# ============================================================================
# 创建目录结构
# ============================================================================
create_directories() {
    log_step "创建目录结构"

    DIRECTORIES=(
        "${INSTALL_DIR}"
        "${BOOT_DIR}/grub"
        "${BOOT_DIR}/pxelinux"
        "${BOOT_DIR}/images/kernels"
        "${BOOT_DIR}/images/initrds"
        "${BOOT_DIR}/images/iso"
        "${CERT_DIR}"
        "${CONFIG_DIR}"
        "${LOG_DIR}"
    )

    for dir in "${DIRECTORIES[@]}"; do
        mkdir -p "${dir}"
        log_info "创建目录: ${dir}"
    done

    # 设置权限
    chmod -R 755 "${INSTALL_DIR}"
    chmod -R 755 "${LOG_DIR}"
}

# ============================================================================
# 生成 SSL 证书
# ============================================================================
generate_ssl_certificate() {
    log_step "生成 SSL 自签名证书"

    if [[ -f "${CERT_DIR}/server.crt" && -f "${CERT_DIR}/server.key" ]]; then
        log_warn "SSL 证书已存在，跳过生成"
        return
    fi

    log_info "生成自签名 SSL 证书..."

    # 生成证书
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" \
        -subj "/C=CN/ST=Beijing/L=Beijing/O=HTTP Boot Server/CN=${SERVER_IP}" \
        -addext "subjectAltName=IP:${SERVER_IP},DNS:localhost"

    # 设置权限
    chmod 600 "${CERT_DIR}/server.key"
    chmod 644 "${CERT_DIR}/server.crt"

    log_info "SSL 证书生成完成: ${CERT_DIR}/server.crt"
}

# ============================================================================
# 配置 DHCP 服务器
# ============================================================================
configure_dhcp() {
    log_step "配置 DHCP 服务器"

    cat > /etc/dhcp/dhcpd.conf << EOF
# HTTP Boot Server - DHCP 配置
# 自动生成于 $(date)
# 支持 BIOS PXE (TFTP) 和 UEFI (TFTP + HTTP Boot)

# 全局选项
default-lease-time 600;
max-lease-time 7200;
authoritative;

# PXE 启动配置
allow booting;
allow bootp;

# 声明 Client System Architecture 选项（option 93）
option arch code 93 = unsigned integer 16;

# 子网配置
subnet ${DHCP_SUBNET} netmask ${DHCP_NETMASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option routers ${DHCP_GATEWAY};
    option domain-name-servers ${DHCP_DNS};
    option domain-name "local";

    # 下一个服务器（TFTP 服务器地址）
    next-server ${SERVER_IP};

    # ============================================================================
    # BIOS PXE 启动 (Architecture 00:00) - 使用 TFTP
    # ============================================================================
    if option arch = 00:00 {
        # BIOS 系统通过 TFTP 下载 pxelinux.0
        filename "pxelinux/pxelinux.0";
    }
    # ============================================================================
    # UEFI x86_64 启动 (Architecture 00:07) - 支持 TFTP 和 HTTP
    # ============================================================================
    else if option arch = 00:07 {
        # 方式一：TFTP（默认，兼容性更好）
        filename "grub/shimx64.efi";
    }
    # ============================================================================
    # UEFI x86 启动 (Architecture 00:06) - 支持 TFTP 和 HTTP
    # ============================================================================
    else if option arch = 00:06 {
        # 方式一：TFTP（默认，兼容性更好）
        filename "grub/shimia32.efi";
    }
    # ============================================================================
    # ARM64 UEFI 启动 (Architecture 00:0b) - 支持 TFTP 和 HTTP
    # ============================================================================
    else if option arch = 00:0b {
        # 方式一：TFTP（默认，兼容性更好）
        filename "grub/grubaa64.efi";
    }
    # ============================================================================
    # 默认使用 UEFI x86_64
    # ============================================================================
    else {
        filename "grub/grubx64.efi";
    }
}

# ============================================================================
# 固定 IP 分配（可选）
# 用于需要固定 IP 的 PXE 客户端
# ============================================================================
# host bios-client {
#     hardware ethernet 00:11:22:33:44:55;
#     fixed-address 192.168.1.10;
#     option host-name "pxe-bios";
# }

# host uefi-client {
#     hardware ethernet 66:77:88:99:aa:bb;
#     fixed-address 192.168.1.11;
#     option host-name "pxe-uefi";
# }

# ============================================================================
# 类别定义（用于区分不同类型的客户端）
# ============================================================================
# class "bios-clients" {
#     match if option arch = 00:00;
# }

# class "uefi-clients" {
#     match if option arch = 00:07 or option arch = 00:06 or option arch = 00:0b;
# }
EOF

    log_info "DHCP 配置完成: /etc/dhcp/dhcpd.conf"
}

# ============================================================================
# 配置 TFTP 服务器
# ============================================================================
configure_tftp() {
    log_step "配置 TFTP 服务器"

    # 备份原配置
    if [[ -f /etc/xinetd.d/tftp ]]; then
        cp /etc/xinetd.d/tftp /etc/xinetd.d/tftp.bak
    fi

    # 配置 xinetd
    cat > /etc/xinetd.d/tftp << EOF
service tftp
{
    socket_type = dgram
    protocol = udp
    wait = yes
    user = root
    server = /usr/sbin/in.tftpd
    server_args = -s ${BOOT_DIR} -c
    disable = no
    per_source = 11
    cps = 100 2
    flags = IPv4
}
EOF

    log_info "TFTP 配置完成"
}

# ============================================================================
# 配置 GRUB 引导文件
# ============================================================================
configure_grub() {
    log_step "配置 GRUB 引导文件"

    # 生成 GRUB 配置文件
    cat > "${BOOT_DIR}/grub/grub.cfg" << 'EOF'
# GRUB 配置文件 - HTTP Boot Server
# 自动检测可用的内核和 initrd

set default=0
set timeout=10

# 设置颜色
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

# HTTP Boot 服务器菜单
menuentry "Boot from HTTP Boot Server" {
    echo "Loading kernel..."
    linuxefi http://${next_server}/boot/images/kernels/vmlinuz inst.repo=http://${next_server}/boot/images/iso/ ip=dhcp
    echo "Loading initial ramdisk..."
    initrdefi http://${next_server}/boot/images/initrds/initramfs.img
    boot
}

menuentry "Boot from Local Disk" {
    set root=(hd0,1)
    chainloader +1
}

menuentry "Rescue Mode" {
    linuxefi http://${next_server}/boot/images/kernels/vmlinuz inst.repo=http://${next_server}/boot/images/iso/ ip=dhcp rescue
    initrdefi http://${next_server}/boot/images/initrds/initramfs.img
    boot
}
EOF

    # 复制 GRUB EFI 文件（如果存在）
    if [[ -f /boot/efi/EFI/redhat/grubx64.efi ]]; then
        cp /boot/efi/EFI/redhat/grubx64.efi "${BOOT_DIR}/grub/"
    elif [[ -f /boot/efi/EFI/centos/grubx64.efi ]]; then
        cp /boot/efi/EFI/centos/grubx64.efi "${BOOT_DIR}/grub/"
    else
        log_warn "未找到 GRUB EFI 文件，请手动复制到 ${BOOT_DIR}/grub/"
    fi

    # 复制 shim 文件（如果存在）
    if [[ -f /boot/efi/EFI/redhat/shimx64.efi ]]; then
        cp /boot/efi/EFI/redhat/shimx64.efi "${BOOT_DIR}/grub/"
    elif [[ -f /boot/efi/EFI/centos/shimx64.efi ]]; then
        cp /boot/efi/EFI/centos/shimx64.efi "${BOOT_DIR}/grub/"
    fi

    log_info "GRUB 配置完成"
}

# ============================================================================
# 配置 PXE 启动文件
# ============================================================================
configure_pxe() {
    log_step "配置 PXE 启动文件"

    # 创建 PXE 配置目录
    mkdir -p "${BOOT_DIR}/pxelinux/pxelinux.cfg"

    # 生成 PXE 配置文件 - 默认启动菜单
    cat > "${BOOT_DIR}/pxelinux/pxelinux.cfg/default" << EOF
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50

MENU TITLE HTTP Boot Server - PXE Menu
MENU BACKGROUND #FF000000
MENU COLOR TITLE 1;36;44
MENU COLOR SEL 7;37;40
MENU COLOR MSG 1;37;40
MENU COLOR TIMEOUT 1;37;40
MENU COLOR TABMSG 1;37;40

LABEL local
    MENU LABEL Boot from ^Local Disk
    LOCALBOOT 0

LABEL linux
    MENU LABEL ^Install RHEL from HTTP Boot Server
    KERNEL http://${SERVER_IP}/boot/images/kernels/vmlinuz
    APPEND initrd=http://${SERVER_IP}/boot/images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp

LABEL linux_tftp
    MENU LABEL Install RHEL via ^TFTP
    KERNEL images/kernels/vmlinuz
    APPEND initrd=images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp

LABEL rescue
    MENU LABEL ^Rescue Mode (HTTP)
    KERNEL http://${SERVER_IP}/boot/images/kernels/vmlinuz
    APPEND initrd=http://${SERVER_IP}/boot/images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp rescue

LABEL rescue_tftp
    MENU LABEL Rescue Mode (^TFTP)
    KERNEL images/kernels/vmlinuz
    APPEND initrd=images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp rescue

LABEL memtest
    MENU LABEL ^Memory Test (memtest86+)
    KERNEL http://${SERVER_IP}/boot/memtest86+.bin

LABEL reboot
    MENU LABEL ^Reboot
    KERNEL reboot.c32

LABEL halt
    MENU LABEL ^Shutdown
    KERNEL halt.c32

TIMEOUT 50
EOF

    # 生成 BIOS PXE 配置
    cat > "${BOOT_DIR}/pxelinux/pxelinux.cfg/bios" << EOF
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50

MENU TITLE BIOS PXE Boot Menu

LABEL install
    MENU LABEL ^Install RHEL (HTTP)
    KERNEL http://${SERVER_IP}/boot/images/kernels/vmlinuz
    APPEND initrd=http://${SERVER_IP}/boot/images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp

LABEL install_tftp
    MENU LABEL Install RHEL (^TFTP)
    KERNEL images/kernels/vmlinuz
    APPEND initrd=images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp

LABEL rescue
    MENU LABEL ^Rescue Mode (HTTP)
    KERNEL http://${SERVER_IP}/boot/images/kernels/vmlinuz
    APPEND initrd=http://${SERVER_IP}/boot/images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp rescue

LABEL rescue_tftp
    MENU LABEL Rescue Mode (^TFTP)
    KERNEL images/kernels/vmlinuz
    APPEND initrd=images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp rescue

LABEL local
    MENU LABEL Boot from ^Local Disk
    LOCALBOOT 0

LABEL reboot
    MENU LABEL ^Reboot
    KERNEL reboot.c32

LABEL halt
    MENU LABEL ^Shutdown
    KERNEL halt.c32
EOF

    # 生成 UEFI PXE 配置
    cat > "${BOOT_DIR}/pxelinux/pxelinux.cfg/uefi" << EOF
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50

MENU TITLE UEFI PXE Boot Menu (TFTP + HTTP)

LABEL install_http
    MENU LABEL ^Install RHEL (HTTP Boot)
    KERNEL http://${SERVER_IP}/boot/images/kernels/vmlinuz
    APPEND initrd=http://${SERVER_IP}/boot/images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp

LABEL install_tftp
    MENU LABEL Install RHEL (^TFTP Boot)
    KERNEL images/kernels/vmlinuz
    APPEND initrd=images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp

LABEL rescue_http
    MENU LABEL Rescue Mode (^HTTP)
    KERNEL http://${SERVER_IP}/boot/images/kernels/vmlinuz
    APPEND initrd=http://${SERVER_IP}/boot/images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp rescue

LABEL rescue_tftp
    MENU LABEL Rescue Mode (^TFTP)
    KERNEL images/kernels/vmlinuz
    APPEND initrd=images/initrds/initramfs.img inst.repo=http://${SERVER_IP}/boot/images/iso/ ip=dhcp rescue

LABEL local
    MENU LABEL Boot from ^Local Disk
    LOCALBOOT 0

LABEL reboot
    MENU LABEL ^Reboot
    KERNEL reboot.c32

LABEL halt
    MENU LABEL ^Shutdown
    KERNEL halt.c32
EOF

    # 复制 PXE 所需文件
    if [[ -f /usr/share/syslinux/pxelinux.0 ]]; then
        cp /usr/share/syslinux/pxelinux.0 "${BOOT_DIR}/pxelinux/"
    elif [[ -f /usr/lib/PXELINUX/pxelinux.0 ]]; then
        cp /usr/lib/PXELINUX/pxelinux.0 "${BOOT_DIR}/pxelinux/"
    fi

    # 复制 syslinux 模块文件（支持 TFTP 下载）
    for module in menu.c32 reboot.c32 halt.c32 libutil.c32 libcom32.c32 mboot.c32 tftp.c32; do
        if [[ -f /usr/share/syslinux/${module} ]]; then
            cp /usr/share/syslinux/${module} "${BOOT_DIR}/pxelinux/"
        fi
    done

    log_info "PXE 配置完成"
}

# ============================================================================
# 配置 Nginx
# ============================================================================
configure_nginx() {
    log_step "配置 Nginx"

    # 备份原配置
    if [[ -f /etc/nginx/nginx.conf ]]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    fi

    # 主配置文件
    cat > /etc/nginx/nginx.conf << EOF
# HTTP Boot Server - Nginx 配置
# 支持 PXE/UEFI HTTP Boot

user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    client_max_body_size 10G;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # HTTP 重定向到 HTTPS
    server {
        listen 80;
        listen [::]:80;
        server_name _;
        return 301 https://\$host\$request_uri;
    }

    # HTTPS 配置 - 主要服务
    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name _;

        ssl_certificate /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers on;

        # 主页 - 重定向到上传界面
        location / {
            return 302 /upload/;
        }

        # 上传管理界面
        location /upload/ {
            proxy_pass http://127.0.0.1:8443/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        # 上传 API
        location /api/ {
            proxy_pass http://127.0.0.1:8443/api/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            client_max_body_size 10G;
        }

        # Boot 文件服务（HTTP/UEFI Boot）
        location /boot/ {
            alias /var/lib/http-boot-server/boot/;
            autoindex on;
            autoindex_exact_size off;
            autoindex_localtime on;

            # 为 EFI 文件设置正确的 MIME 类型
            location ~* \\.efi\$ {
                add_header Content-Type application/octet-stream;
            }
        }

        # UEFI HTTP Boot 专用端点 - grubx64.efi
        location = /grubx64.efi {
            alias /var/lib/http-boot-server/boot/grub/grubx64.efi;
            add_header Content-Type application/octet-stream;
        }

        # UEFI HTTP Boot 专用端点 - shimx64.efi
        location = /shimx64.efi {
            alias /var/lib/http-boot-server/boot/grub/shimx64.efi;
            add_header Content-Type application/octet-stream;
        }

        # UEFI HTTP Boot 专用端点 - grubaa64.efi
        location = /grubaa64.efi {
            alias /var/lib/http-boot-server/boot/grub/grubaa64.efi;
            add_header Content-Type application/octet-stream;
        }

        # GRUB 配置文件
        location = /grub.cfg {
            alias /var/lib/http-boot-server/boot/grub/grub.cfg;
            add_header Content-Type text/plain;
        }

        # PXE 配置文件
        location = /pxelinux.cfg/default {
            alias /var/lib/http-boot-server/boot/pxelinux/pxelinux.cfg/default;
            add_header Content-Type text/plain;
        }

        # 静态文件缓存
        location ~* \\.(jpg|jpeg|png|gif|ico|css|js)\$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }
}
EOF

    # 创建 SSL 证书符号链接
    mkdir -p /etc/nginx/ssl
    ln -sf "${CERT_DIR}/server.crt" /etc/nginx/ssl/server.crt
    ln -sf "${CERT_DIR}/server.key" /etc/nginx/ssl/server.key

    log_info "Nginx 配置完成"
}

# ============================================================================
# 配置 Flask 上传服务
# ============================================================================
configure_flask_service() {
    log_step "配置 Flask 上传服务"

    # 复制 Flask 应用文件
    cp "${SCRIPT_DIR}/upload_server.py" "${INSTALL_DIR}/"
    cp -r "${SCRIPT_DIR}/templates" "${INSTALL_DIR}/"

    # 创建 systemd 服务文件
    cat > /etc/systemd/system/http-boot-upload.service << EOF
[Unit]
Description=HTTP Boot Server - Upload Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/upload_server.py
Restart=always
RestartSec=5
Environment=INSTALL_DIR=${INSTALL_DIR}
Environment=UPLOAD_PORT=${UPLOAD_PORT}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    log_info "Flask 上传服务配置完成"
}

# ============================================================================
# 配置防火墙
# ============================================================================
configure_firewall() {
    log_step "配置防火墙"

    # 启动 firewalld
    systemctl enable --now firewalld

    # 开放端口
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port=69/udp    # TFTP
    firewall-cmd --permanent --add-port=67/udp    # DHCP
    firewall-cmd --permanent --add-port=68/udp    # DHCP
    firewall-cmd --permanent --add-port=8443/tcp  # Upload Service

    # 重新加载防火墙
    firewall-cmd --reload

    log_info "防火墙配置完成"
}

# ============================================================================
# 启动服务
# ============================================================================
start_services() {
    log_step "启动服务"

    # 启动 TFTP
    log_info "启动 TFTP 服务..."
    systemctl enable --now xinetd
    systemctl restart xinetd

    # 启动 DHCP
    log_info "启动 DHCP 服务..."
    systemctl enable --now dhcpd
    systemctl restart dhcpd

    # 启动 Nginx
    log_info "启动 Nginx 服务..."
    systemctl enable --now nginx
    systemctl restart nginx

    # 启动 Flask 上传服务
    log_info "启动 Flask 上传服务..."
    systemctl enable --now http-boot-upload
    systemctl restart http-boot-upload

    log_info "所有服务启动完成"
}

# ============================================================================
# 显示部署信息
# ============================================================================
show_deployment_info() {
    log_step "部署完成"

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   HTTP Boot Server 部署成功!${NC}"
    echo -e "${GREEN}   支持 BIOS PXE 和 UEFI (TFTP + HTTP)${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "服务器信息:"
    echo -e "  IP 地址: ${BLUE}${SERVER_IP}${NC}"
    echo -e "  Web 管理界面: ${BLUE}https://${SERVER_IP}:${HTTPS_PORT}/upload/${NC}"
    echo -e "  Boot 文件服务: ${BLUE}https://${SERVER_IP}:${HTTPS_PORT}/boot/${NC}"
    echo ""
    echo -e "${YELLOW}BIOS PXE 启动 (TFTP):${NC}"
    echo -e "  引导文件: ${BLUE}pxelinux/pxelinux.0${NC}"
    echo -e "  配置文件: ${BLUE}pxelinux/pxelinux.cfg/default${NC}"
    echo -e "  TFTP 地址: ${BLUE}tftp://${SERVER_IP}/pxelinux/pxelinux.0${NC}"
    echo ""
    echo -e "${YELLOW}UEFI 启动 (TFTP + HTTP):${NC}"
    echo -e "  x86_64 引导: ${BLUE}grub/shimx64.efi${NC} (推荐)"
    echo -e "  x86_64 备用: ${BLUE}grub/grubx64.efi${NC}"
    echo -e "  x86 引导: ${BLUE}grub/shimia32.efi${NC}"
    echo -e "  ARM64 引导: ${BLUE}grub/grubaa64.efi${NC}"
    echo -e "  TFTP 地址: ${BLUE}tftp://${SERVER_IP}/grub/shimx64.efi${NC}"
    echo -e "  HTTP 地址: ${BLUE}https://${SERVER_IP}/boot/grub/grub.cfg${NC}"
    echo ""
    echo -e "DHCP 配置:"
    echo -e "  下一个服务器: ${BLUE}${SERVER_IP}${NC}"
    echo -e "  BIOS (00:00): ${BLUE}pxelinux/pxelinux.0${NC}"
    echo -e "  UEFI x86_64 (00:07): ${BLUE}grub/shimx64.efi${NC}"
    echo -e "  UEFI x86 (00:06): ${BLUE}grub/shimia32.efi${NC}"
    echo -e "  UEFI ARM64 (00:0b): ${BLUE}grub/grubaa64.efi${NC}"
    echo ""
    echo -e "镜像存储位置:"
    echo -e "  内核文件: ${BLUE}${BOOT_DIR}/images/kernels/${NC}"
    echo -e "  initrd 文件: ${BLUE}${BOOT_DIR}/images/initrds/${NC}"
    echo -e "  ISO 文件: ${BLUE}${BOOT_DIR}/images/iso/${NC}"
    echo ""
    echo -e "服务管理:"
    echo -e "  DHCP: ${BLUE}systemctl {start|stop|restart|status} dhcpd${NC}"
    echo -e "  TFTP: ${BLUE}systemctl {start|stop|restart|status} xinetd${NC}"
    echo -e "  Nginx: ${BLUE}systemctl {start|stop|restart|status} nginx${NC}"
    echo -e "  Upload: ${BLUE}systemctl {start|stop|restart|status} http-boot-upload${NC}"
    echo ""
    echo -e "PXE/UEFI 启动说明:"
    echo -e "  1. 客户端设置从网络启动"
    echo -e "  2. DHCP 自动分配 IP 并根据架构提供引导文件"
    echo -e "  3. BIOS 客户端通过 TFTP 下载 pxelinux.0"
    echo -e "  4. UEFI 客户端通过 TFTP 下载 shimx64.efi/grubx64.efi"
    echo -e "  5. 加载启动菜单，选择安装选项（支持 TFTP 和 HTTP 两种方式）"
    echo -e "  6. 下载内核和 initrd，开始安装"
    echo ""
    echo -e "${YELLOW}提示: 请将需要启动的内核和 initrd 文件上传到 Web 管理界面${NC}"
    echo -e "${YELLOW}或者手动复制到 ${BOOT_DIR}/images/ 目录${NC}"
    echo ""
    echo -e "${YELLOW}UEFI 启动方式:${NC}"
    echo -e "  - TFTP 方式：通过 tftp://${SERVER_IP}/grub/grub.cfg 加载配置"
    echo -e "  - HTTP 方式：通过 https://${SERVER_IP}/boot/grub/grub.cfg 加载配置"
    echo -e "  - 启动菜单同时支持 TFTP 和 HTTP 两种方式下载内核/initrd"
    echo ""
}

# ============================================================================
# 主函数
# ============================================================================
main() {
    log_step "HTTP Boot Server 一键部署脚本"

    # 检查权限
    check_root

    # 检查系统
    check_rhel

    # 检测网络
    detect_network

    # 安装依赖
    install_dependencies

    # 创建目录
    create_directories

    # 生成 SSL 证书
    generate_ssl_certificate

    # 配置服务
    configure_dhcp
    configure_tftp
    configure_grub
    configure_pxe
    configure_nginx
    configure_flask_service

    # 配置防火墙
    configure_firewall

    # 启动服务
    start_services

    # 显示信息
    show_deployment_info
}

# 运行主函数
main "$@"
