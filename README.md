# HTTP Boot Server

一键部署的 PXE/UEFI HTTP Boot 服务器，支持 Web 界面上传镜像，HTTPS 加密。

## 功能特性

- **PXE/UEFI 网络启动** - 完整支持 BIOS PXE 和 UEFI HTTP Boot
- **多架构支持** - 支持 x86_64、x86、ARM64 架构
- **Web 管理界面** - 拖拽上传镜像文件，管理启动文件
- **HTTPS 加密** - 自动生成自签名 SSL 证书
- **自动配置** - 一键部署 DHCP、TFTP、Nginx 服务
- **智能 DHCP** - 自动根据客户端架构提供对应引导文件

## 系统要求

- RHEL 7/8/9 或兼容系统（CentOS、Rocky Linux 等）
- Ubuntu 20.04+ 或 Debian 11+
- Root 权限
- 至少 10GB 可用磁盘空间

## 快速开始

### 1. 下载项目

```bash
git clone git@github.com:lizia102/http-boot-server.git
cd http-boot-server
```

### 2. 一键部署

```bash
chmod +x setup.sh
sudo ./setup.sh
```

部署脚本会自动：
- 安装所有依赖包
- 生成自签名 SSL 证书
- 配置 DHCP、TFTP、Nginx 服务
- 配置防火墙规则
- 启动所有服务

### 3. 访问管理界面

部署完成后，访问以下地址：

- **Web 管理界面**: `https://<服务器IP>/upload/`
- **Boot 文件服务**: `https://<服务器IP>/boot/`

### 4. 上传启动文件

通过 Web 界面上传以下文件：

**RHEL/CentOS:**
1. **内核文件** (vmlinuz) - 从安装介质的 `images/pxeboot/` 提取
2. **initrd 文件** (initramfs.img) - 从安装介质的 `images/pxeboot/` 提取
3. **ISO 镜像** (可选) - 完整的安装镜像

**Ubuntu/Debian:**
1. **内核文件** (vmlinuz) - 从 ISO 的 `casper/` 目录提取
2. **initrd 文件** (initrd) - 从 ISO 的 `casper/` 目录提取，重命名为 `initrd.img`
3. **ISO 镜像** - Ubuntu Server ISO（启动菜单通过 `url=` 参数指定 ISO 路径）

## 目录结构

```
/var/lib/http-boot-server/
├── boot/
│   ├── grub/                 # GRUB 引导文件
│   │   ├── grubx64.efi       # UEFI x86_64 引导程序
│   │   ├── shimx64.efi       # UEFI x86_64 Shim 引导程序
│   │   ├── grubia32.efi      # UEFI x86 引导程序
│   │   ├── shimia32.efi      # UEFI x86 Shim 引导程序
│   │   ├── grubaa64.efi      # UEFI ARM64 引导程序
│   │   └── grub.cfg          # GRUB 配置
│   ├── pxelinux/             # BIOS PXE 引导文件
│   │   ├── pxelinux.0        # PXE 引导程序
│   │   ├── menu.c32          # 菜单模块
│   │   ├── reboot.c32        # 重启模块
│   │   ├── halt.c32          # 关机模块
│   │   └── pxelinux.cfg/     # PXE 配置目录
│   │       ├── default       # 默认配置
│   │       ├── bios          # BIOS 专用配置
│   │       └── uefi          # UEFI 专用配置
│   └── images/               # 镜像存储目录
│       ├── kernels/          # 内核文件
│       ├── initrds/          # initrd 文件
│       └── iso/              # ISO 镜像
├── certs/                    # SSL 证书
│   ├── server.crt
│   └── server.key
└── config/                   # 配置文件
    ├── dhcpd.conf.template   # DHCP 配置模板
    └── nginx.conf            # Nginx 配置
```

## 服务管理

### 查看服务状态

```bash
# DHCP 服务
systemctl status dhcpd

# TFTP 服务
systemctl status tftp.socket

# Nginx 服务
systemctl status nginx

# 上传服务
systemctl status http-boot-upload
```

### 重启服务

```bash
# 重启所有服务
systemctl restart dhcpd tftp.socket nginx http-boot-upload

# 重启单个服务
systemctl restart nginx
```

### 查看日志

```bash
# DHCP 日志
journalctl -u dhcpd

# Nginx 日志
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log

# 上传服务日志
journalctl -u http-boot-upload
```

## 客户端启动

### BIOS PXE 启动

1. 客户端设置从网络启动（PXE）
2. DHCP 服务器检测到 BIOS 客户端（arch = 00:00）
3. 提供引导文件 `pxelinux/pxelinux.0`
4. 下载 PXE 配置文件 `pxelinux.cfg/default`
5. 显示启动菜单
6. 下载内核和 initrd
7. 开始安装

**DHCP 配置示例：**
```dhcp
if option arch = 00:00 {
    filename "pxelinux/pxelinux.0";
}
```

### UEFI 启动 (TFTP + HTTP)

UEFI 系统支持两种引导方式：

#### 方式一：TFTP 引导（推荐，兼容性更好）

1. 客户端设置从网络启动（PXE）
2. DHCP 服务器检测到 UEFI 客户端架构
3. 通过 TFTP 提供对应的引导文件：
   - x86_64: `grub/shimx64.efi` 或 `grub/grubx64.efi`
   - x86: `grub/shimia32.efi`
   - ARM64: `grub/grubaa64.efi`
4. 下载 GRUB 配置文件 `tftp://<服务器IP>/grub/grub.cfg`
5. 显示启动菜单（支持 TFTP 和 HTTP 两种方式下载内核）
6. 通过 TFTP 或 HTTP 下载内核和 initrd
7. 开始安装

#### 方式二：HTTP Boot 引导

1. 客户端设置从网络启动（HTTP Boot）
2. DHCP 服务器提供 UEFI 引导文件
3. 通过 HTTP/HTTPS 下载 GRUB 配置文件
4. 显示启动菜单
5. 通过 HTTP/HTTPS 下载内核和 initrd
6. 开始安装

**DHCP 配置示例：**
```dhcp
# UEFI x86_64
if option arch = 00:07 {
    filename "grub/shimx64.efi";
}

# UEFI x86
else if option arch = 00:06 {
    filename "grub/shimia32.efi";
}

# UEFI ARM64
else if option arch = 00:0b {
    filename "grub/grubaa64.efi";
}
```

### UEFI 客户端设置

1. 进入 UEFI/BIOS 设置
2. 启用 HTTP Boot 选项
3. 设置 HTTP Boot URL:
   ```
   https://<服务器IP>/boot/grub/grub.cfg
   ```
4. 保存并重启

### Ubuntu/Debian 网络启动

启动菜单中包含 Ubuntu 专用选项，需要提前准备以下文件：

1. 从 Ubuntu ISO 的 `casper/` 目录提取 `vmlinuz` 和 `initrd`
2. 上传到 Web 管理界面的对应目录
3. 将 Ubuntu ISO 上传到 ISO 目录
4. 客户端启动后选择 "Install Ubuntu" 菜单项

Ubuntu 启动参数说明：
- `url=` - 指定 ISO 镜像的 HTTP 地址
- `autoinstall` - 启用自动化安装（需配合 cloud-init 配置）

### 测试 PXE/UEFI 启动

```bash
# 检查 DHCP 配置
cat /etc/dhcp/dhcpd.conf

# 检查 TFTP 服务
systemctl status tftp.socket

# 检查 Nginx 服务
systemctl status nginx

# 测试 TFTP 连接 - BIOS PXE
tftp <服务器IP>
tftp> get pxelinux/pxelinux.0

# 测试 TFTP 连接 - UEFI 引导文件
tftp <服务器IP>
tftp> get grub/shimx64.efi

# 测试 TFTP 连接 - UEFI GRUB 配置
tftp <服务器IP>
tftp> get grub/grub.cfg

# 测试 HTTP 连接
curl -k https://<服务器IP>/boot/grub/grub.cfg

# 测试 HTTP 连接 - EFI 文件
curl -k -I https://<服务器IP>/boot/grub/grubx64.efi
```

## 配置说明

### 修改网络配置

编辑 `setup.sh` 中的配置变量：

```bash
# DHCP 范围
DHCP_RANGE_START="192.168.1.100"
DHCP_RANGE_END="192.168.1.200"

# 端口配置
HTTP_PORT=80
HTTPS_PORT=443
UPLOAD_PORT=8443
```

### 自定义 GRUB 配置

编辑 `/var/lib/http-boot-server/boot/grub/grub.cfg`

### 重新部署

```bash
# 完全重新部署
sudo ./setup.sh

# 仅更新配置
sudo ./setup.sh --update-config
```

## 故障排查

### DHCP 服务无法启动

```bash
# 检查配置
cat /etc/dhcp/dhcpd.conf

# 检查端口
ss -tulnp | grep :67

# 查看日志
journalctl -u dhcpd
```

### TFTP 服务无法启动

```bash
# 检查 TFTP 配置（RHEL）
cat /etc/sysconfig/tftpd

# 检查 TFTP 配置（Debian/Ubuntu）
cat /etc/default/tftpd-hpa

# 检查端口
ss -tulnp | grep :69

# 测试 TFTP
tftp localhost
```

### Nginx 服务无法启动

```bash
# 检查配置
nginx -t

# 检查证书
ls -la /etc/nginx/ssl/

# 查看日志
tail -f /var/log/nginx/error.log
```

### 上传服务无法启动

```bash
# 检查 Python 和 Flask
python3 -c "import flask; print(flask.__version__)"

# 查看日志
journalctl -u http-boot-upload

# 手动启动测试
cd /var/lib/http-boot-server
python3 upload_server.py
```

## 安全建议

1. **修改默认密码** - 如需启用身份验证，请修改 `upload_server.py`
2. **限制访问** - 通过防火墙限制可访问的 IP 范围
3. **定期更新** - 保持系统和软件包更新
4. **备份配置** - 定期备份 `/var/lib/http-boot-server/config/`

## 许可证

MIT License
