#!/usr/bin/env python3
"""
HTTP Boot Server - 镜像上传管理服务
提供 Web 界面上传、删除、管理启动镜像
"""

import os
import ssl
from datetime import datetime
from flask import Flask, render_template, request, jsonify, send_file
from werkzeug.utils import secure_filename

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024 * 1024  # 10GB 最大上传限制

# 配置
INSTALL_DIR = os.environ.get('INSTALL_DIR', '/var/lib/http-boot-server')
BOOT_DIR = os.path.join(INSTALL_DIR, 'boot')
CERT_DIR = os.path.join(INSTALL_DIR, 'certs')
UPLOAD_PORT = int(os.environ.get('UPLOAD_PORT', 8443))

# 支持的文件类型
ALLOWED_EXTENSIONS = {
    'kernels': {'vmlinuz', 'bzImage', 'vmlinux'},
    'initrds': {'initrd', 'initramfs', 'initrd.img', 'initramfs.img'},
    'iso': {'iso'}
}

def allowed_file(filename, file_type):
    """检查文件是否允许上传"""
    allowed = ALLOWED_EXTENSIONS.get(file_type, set())
    # 扩展名匹配：vmlinuz、initrd.img、iso 等
    if '.' in filename:
        ext = filename.rsplit('.', 1)[1].lower()
        if ext in allowed:
            return True
        # 处理 .img-5.15.0-generic 这类 Ubuntu 命名
        for aext in allowed:
            if ext.startswith(aext):
                return True
    # 前缀匹配：处理 vmlinuz-5.15.0-generic 等无标准扩展名的内核文件
    basename = filename.lower()
    if file_type == 'kernels' and basename.startswith('vmlinuz'):
        return True
    if file_type == 'initrds' and (basename.startswith('initrd') or basename.startswith('initramfs')):
        return True
    return False

def validate_file_type(file_type):
    """校验 file_type 是否合法，防止路径穿越"""
    return file_type in ALLOWED_EXTENSIONS

def get_file_info(filepath):
    """获取文件信息"""
    stat = os.stat(filepath)
    return {
        'name': os.path.basename(filepath),
        'size': stat.st_size,
        'size_human': format_size(stat.st_size),
        'modified': datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S'),
    }

def format_size(size_bytes):
    """格式化文件大小"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.1f} PB"

def list_images(subdir):
    """列出指定目录下的镜像文件"""
    if not validate_file_type(subdir):
        return []
    dir_path = os.path.join(BOOT_DIR, 'images', subdir)
    if not os.path.exists(dir_path):
        return []
    files = []
    for f in os.listdir(dir_path):
        filepath = os.path.join(dir_path, f)
        if os.path.isfile(filepath) and allowed_file(f, subdir):
            files.append(get_file_info(filepath))
    return sorted(files, key=lambda x: x['modified'], reverse=True)

@app.route('/')
def index():
    """主页 - 显示所有镜像"""
    kernels = list_images('kernels')
    initrds = list_images('initrds')
    isos = list_images('iso')
    return render_template('index.html',
                         kernels=kernels,
                         initrds=initrds,
                         isos=isos,
                         server_ip=request.host.split(':')[0])

@app.route('/api/upload', methods=['POST'])
def upload_file():
    """上传文件 API"""
    if 'file' not in request.files:
        return jsonify({'error': '没有选择文件'}), 400

    file = request.files['file']
    file_type = request.form.get('type', 'kernels')

    if file.filename == '':
        return jsonify({'error': '没有选择文件'}), 400

    if not validate_file_type(file_type):
        return jsonify({'error': f'无效的文件类型: {file_type}'}), 400

    if not allowed_file(file.filename, file_type):
        return jsonify({'error': f'不支持的文件类型，允许: {", ".join(ALLOWED_EXTENSIONS.get(file_type, set()))}'}), 400

    # 安全处理文件名
    filename = secure_filename(file.filename)
    if not filename:
        filename = f"image_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

    # 确定保存路径
    save_dir = os.path.join(BOOT_DIR, 'images', file_type)
    os.makedirs(save_dir, exist_ok=True)
    save_path = os.path.join(save_dir, filename)

    # 检查文件是否已存在
    if os.path.exists(save_path):
        name, ext = os.path.splitext(filename)
        filename = f"{name}_{datetime.now().strftime('%Y%m%d_%H%M%S')}{ext}"
        save_path = os.path.join(save_dir, filename)

    # 保存文件
    file.save(save_path)

    # 如果是 ISO 文件，更新 GRUB 配置
    if file_type == 'iso':
        update_grub_config(filename)

    return jsonify({
        'success': True,
        'message': f'文件 {filename} 上传成功',
        'file': get_file_info(save_path)
    })

@app.route('/api/delete', methods=['POST'])
def delete_file():
    """删除文件 API"""
    data = request.get_json()
    filename = data.get('filename')
    file_type = data.get('type', 'kernels')

    if not filename:
        return jsonify({'error': '未指定文件名'}), 400

    if not validate_file_type(file_type):
        return jsonify({'error': f'无效的文件类型: {file_type}'}), 400

    safe_name = secure_filename(filename)
    if not safe_name:
        return jsonify({'error': '无效的文件名'}), 400

    filepath = os.path.join(BOOT_DIR, 'images', file_type, safe_name)

    # 二次校验：确保路径在预期目录内
    real_path = os.path.realpath(filepath)
    expected_dir = os.path.realpath(os.path.join(BOOT_DIR, 'images', file_type))
    if not real_path.startswith(expected_dir):
        return jsonify({'error': '非法路径'}), 400

    if not os.path.exists(filepath):
        return jsonify({'error': '文件不存在'}), 404

    try:
        os.remove(filepath)
        return jsonify({'success': True, 'message': f'文件 {filename} 已删除'})
    except Exception as e:
        return jsonify({'error': f'删除失败: {str(e)}'}), 500

@app.route('/api/download/<file_type>/<filename>')
def download_file(file_type, filename):
    """下载文件"""
    if not validate_file_type(file_type):
        return jsonify({'error': '无效的文件类型'}), 400

    safe_name = secure_filename(filename)
    if not safe_name:
        return jsonify({'error': '无效的文件名'}), 400

    filepath = os.path.join(BOOT_DIR, 'images', file_type, safe_name)

    # 二次校验：确保路径在预期目录内
    real_path = os.path.realpath(filepath)
    expected_dir = os.path.realpath(os.path.join(BOOT_DIR, 'images', file_type))
    if not real_path.startswith(expected_dir):
        return jsonify({'error': '非法路径'}), 400

    if not os.path.exists(filepath):
        return jsonify({'error': '文件不存在'}), 404
    return send_file(filepath, as_attachment=True)

@app.route('/api/files/<file_type>')
def list_files(file_type):
    """列出指定类型的文件"""
    if not validate_file_type(file_type):
        return jsonify({'error': '无效的文件类型'}), 400
    return jsonify(list_images(file_type))

@app.route('/api/info')
def server_info():
    """服务器信息"""
    return jsonify({
        'server_ip': request.host.split(':')[0],
        'boot_dir': BOOT_DIR,
        'https_port': 443,
        'upload_port': UPLOAD_PORT,
        'grub_config': os.path.join(BOOT_DIR, 'grub', 'grub.cfg')
    })

def find_boot_file(subdir):
    """在指定目录中查找可用的启动文件，返回 HTTP 路径"""
    dir_path = os.path.join(BOOT_DIR, 'images', subdir)
    if not os.path.exists(dir_path):
        return None
    for f in sorted(os.listdir(dir_path)):
        if os.path.isfile(os.path.join(dir_path, f)) and allowed_file(f, subdir):
            return f
    return None

def update_grub_config(iso_filename):
    """更新 GRUB 配置以支持新上传的 ISO"""
    grub_config = os.path.join(BOOT_DIR, 'grub', 'grub.cfg')
    if not os.path.exists(grub_config):
        return

    with open(grub_config, 'r') as f:
        content = f.read()

    iso_name = os.path.splitext(iso_filename)[0]
    if iso_name in content:
        return

    server_ip = request.host.split(':')[0]
    iso_lower = iso_filename.lower()

    # 查找实际可用的内核和 initrd 文件
    kernel_file = find_boot_file('kernels')
    initrd_file = find_boot_file('initrds')
    if not kernel_file or not initrd_file:
        return

    kernel_path = f"http://{server_ip}/boot/images/kernels/{kernel_file}"
    initrd_path = f"http://{server_ip}/boot/images/initrds/{initrd_file}"

    # 根据 ISO 类型生成不同的启动参数
    if 'ubuntu' in iso_lower or 'debian' in iso_lower:
        new_entry = f'''
menuentry "Install {iso_name}" {{
    linuxefi {kernel_path} ip=dhcp url=http://{server_ip}/boot/images/iso/{iso_filename} autoinstall
    initrdefi {initrd_path}
    boot
}}
'''
    else:
        new_entry = f'''
menuentry "Install {iso_name}" {{
    linuxefi {kernel_path} inst.repo=http://{server_ip}/boot/images/iso/{iso_filename} ip=dhcp
    initrdefi {initrd_path}
    boot
}}
'''

    # 在第一个 menuentry 之前插入
    marker = 'menuentry "'
    idx = content.find(marker)
    if idx != -1:
        content = content[:idx] + new_entry + content[idx:]
    else:
        content = new_entry + content

    with open(grub_config, 'w') as f:
        f.write(content)

if __name__ == '__main__':
    # 创建必要的目录
    os.makedirs(os.path.join(BOOT_DIR, 'images', 'kernels'), exist_ok=True)
    os.makedirs(os.path.join(BOOT_DIR, 'images', 'initrds'), exist_ok=True)
    os.makedirs(os.path.join(BOOT_DIR, 'images', 'iso'), exist_ok=True)

    # SSL 上下文
    ssl_context = None
    cert_file = os.path.join(CERT_DIR, 'server.crt')
    key_file = os.path.join(CERT_DIR, 'server.key')

    if os.path.exists(cert_file) and os.path.exists(key_file):
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(cert_file, key_file)
        proto = "https"
    else:
        proto = "http"

    print(f"启动 HTTP Boot Server 上传服务...")
    print(f"访问地址: {proto}://localhost:{UPLOAD_PORT}")
    print(f"镜像目录: {BOOT_DIR}/images/")

    app.run(
        host='0.0.0.0',
        port=UPLOAD_PORT,
        ssl_context=ssl_context,
        debug=False
    )
