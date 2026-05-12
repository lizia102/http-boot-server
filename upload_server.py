#!/usr/bin/env python3
"""
HTTP Boot Server - 镜像上传管理服务
提供 Web 界面上传、删除、管理启动镜像
"""

import json
import logging
import os
import re
import shutil
import ssl
import subprocess
import threading
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
METADATA_FILE = os.path.join(BOOT_DIR, 'config', 'metadata.json')
REPOS_DIR = os.path.join(BOOT_DIR, 'repos')

logger = logging.getLogger(__name__)

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

def load_metadata():
    """加载元数据（默认内核/initrd 等）"""
    if os.path.exists(METADATA_FILE):
        with open(METADATA_FILE, 'r') as f:
            return json.load(f)
    return {"defaults": {"kernel": None, "initrd": None}}

def save_metadata(data):
    """保存元数据"""
    os.makedirs(os.path.dirname(METADATA_FILE), exist_ok=True)
    with open(METADATA_FILE, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def extract_iso_repo(iso_filename):
    """解压 ISO 到仓库目录（SLES/SUSE 需要）"""
    iso_path = os.path.join(BOOT_DIR, 'images', 'iso', iso_filename)
    repo_name = os.path.splitext(iso_filename)[0]
    repo_dir = os.path.join(REPOS_DIR, repo_name)

    if os.path.exists(repo_dir):
        return repo_dir

    os.makedirs(repo_dir, exist_ok=True)

    # 使用 bsdtar 解压 ISO
    try:
        result = subprocess.run(
            ['bsdtar', '-xf', iso_path, '-C', repo_dir],
            capture_output=True, text=True, timeout=600
        )
        if result.returncode == 0:
            logger.info(f"ISO 解压成功: {iso_filename} -> {repo_dir}")
            return repo_dir
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # 解压失败，清理空目录
    shutil.rmtree(repo_dir, ignore_errors=True)
    logger.error(f"ISO 解压失败: {iso_filename}，需要安装 libarchive (bsdtar)")
    return None

def extract_iso_repo_async(iso_filename):
    """后台线程解压 ISO"""
    try:
        extract_iso_repo(iso_filename)
    except Exception as e:
        logger.error(f"后台解压 ISO 失败: {e}")

def cleanup_iso_repo(iso_filename):
    """清理 ISO 解压的仓库目录"""
    repo_name = os.path.splitext(iso_filename)[0]
    repo_dir = os.path.join(REPOS_DIR, repo_name)
    if os.path.exists(repo_dir):
        shutil.rmtree(repo_dir, ignore_errors=True)
        logger.info(f"已清理仓库目录: {repo_dir}")

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
    metadata = load_metadata()
    defaults = metadata.get('defaults', {})
    return render_template('index.html',
                         kernels=kernels,
                         initrds=initrds,
                         isos=isos,
                         server_ip=request.host.split(':')[0],
                         default_kernel=defaults.get('kernel'),
                         default_initrd=defaults.get('initrd'))

@app.route('/api/upload', methods=['POST'])
def upload_file():
    """上传文件 API"""
    if 'file' not in request.files:
        return jsonify({'error': '没有选择文件'}), 400

    file = request.files['file']
    file_type = request.form.get('type', 'kernels')
    selected_kernel = request.form.get('kernel', '').strip() or None
    selected_initrd = request.form.get('initrd', '').strip() or None

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
        update_grub_config(filename, kernel_file=selected_kernel, initrd_file=selected_initrd)

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
        # ISO 文件：清理对应的 GRUB 条目和解压目录
        if file_type == 'iso':
            remove_grub_entry(safe_name)
            cleanup_iso_repo(safe_name)
        # 内核/initrd 文件：清除默认设置（如果被设为默认）
        if file_type in ('kernels', 'initrds'):
            clear_default_if_deleted(file_type, safe_name)
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
    """查找启动文件，优先使用配置的默认文件"""
    dir_path = os.path.join(BOOT_DIR, 'images', subdir)
    if not os.path.exists(dir_path):
        return None

    # 优先使用默认文件
    metadata = load_metadata()
    default_key = subdir.rstrip('s')  # 'kernels' -> 'kernel', 'initrds' -> 'initrd'
    default_file = metadata.get('defaults', {}).get(default_key)
    if default_file:
        default_path = os.path.join(dir_path, default_file)
        if os.path.isfile(default_path) and allowed_file(default_file, subdir):
            return default_file

    # 回退：字母序第一个
    for f in sorted(os.listdir(dir_path)):
        if os.path.isfile(os.path.join(dir_path, f)) and allowed_file(f, subdir):
            return f
    return None

def update_grub_config(iso_filename, kernel_file=None, initrd_file=None):
    """更新 GRUB 配置以支持新上传的 ISO"""
    grub_config = os.path.join(BOOT_DIR, 'grub', 'grub.cfg')
    if not os.path.exists(grub_config):
        return

    with open(grub_config, 'r') as f:
        content = f.read()

    iso_name = os.path.splitext(iso_filename)[0]
    # 通过标记或名称检查重复
    if f'# <dynamic iso="{iso_filename}">' in content or iso_name in content:
        return

    server_ip = request.host.split(':')[0]
    iso_lower = iso_filename.lower()

    # 使用指定文件或查找默认文件
    if not kernel_file:
        kernel_file = find_boot_file('kernels')
    if not initrd_file:
        initrd_file = find_boot_file('initrds')
    if not kernel_file or not initrd_file:
        return

    kernel_path = f"http://{server_ip}/boot/images/kernels/{kernel_file}"
    initrd_path = f"http://{server_ip}/boot/images/initrds/{initrd_file}"

    # 根据 ISO 类型生成不同的启动参数和内核路径
    if 'ubuntu' in iso_lower or 'debian' in iso_lower:
        boot_args = f"ip=dhcp url=http://{server_ip}/boot/images/iso/{iso_filename} autoinstall"
        entry_kernel = kernel_path
        entry_initrd = initrd_path
    elif 'sles' in iso_lower or 'suse' in iso_lower:
        # SLES 需要解压后的仓库目录，使用 ISO 内自带的内核
        repo_name = os.path.splitext(iso_filename)[0]
        repo_url = f"http://{server_ip}/boot/repos/{repo_name}"
        boot_args = f"install={repo_url} ip=dhcp"
        entry_kernel = f"{repo_url}/boot/x86_64/loader/linux"
        entry_initrd = f"{repo_url}/boot/x86_64/loader/initrd"
        threading.Thread(target=extract_iso_repo_async, args=(iso_filename,), daemon=True).start()
    else:
        boot_args = f"inst.repo=http://{server_ip}/boot/images/iso/{iso_filename} ip=dhcp"
        entry_kernel = kernel_path
        entry_initrd = initrd_path

    new_entry = f'''
# <dynamic iso="{iso_filename}">
menuentry "Install {iso_name}" {{
    linuxefi {entry_kernel} {boot_args}
    initrdefi {entry_initrd}
    boot
}}
# </dynamic>
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

def remove_grub_entry(iso_filename):
    """删除 ISO 对应的动态 GRUB 条目"""
    grub_config = os.path.join(BOOT_DIR, 'grub', 'grub.cfg')
    if not os.path.exists(grub_config):
        return False

    with open(grub_config, 'r') as f:
        content = f.read()

    pattern = r'\n# <dynamic iso="' + re.escape(iso_filename) + r'">\n.*?# </dynamic>\n'
    new_content, count = re.subn(pattern, '\n', content, flags=re.DOTALL)

    if count > 0:
        with open(grub_config, 'w') as f:
            f.write(new_content)
        return True
    return False

def clear_default_if_deleted(file_type, filename):
    """如果删除的文件是默认内核/initrd，清除默认设置"""
    metadata = load_metadata()
    defaults = metadata.get('defaults', {})
    default_key = file_type.rstrip('s')  # 'kernels' -> 'kernel'
    if defaults.get(default_key) == filename:
        defaults[default_key] = None
        save_metadata(metadata)

@app.route('/api/defaults', methods=['GET', 'POST'])
def manage_defaults():
    """获取或设置默认内核/initrd"""
    if request.method == 'GET':
        return jsonify(load_metadata().get('defaults', {}))

    data = request.get_json()
    metadata = load_metadata()

    if 'kernel' in data:
        if data['kernel']:
            kernel_path = os.path.join(BOOT_DIR, 'images', 'kernels', secure_filename(data['kernel']))
            if not os.path.exists(kernel_path):
                return jsonify({'error': '指定的内核文件不存在'}), 400
        metadata['defaults']['kernel'] = data['kernel'] or None

    if 'initrd' in data:
        if data['initrd']:
            initrd_path = os.path.join(BOOT_DIR, 'images', 'initrds', secure_filename(data['initrd']))
            if not os.path.exists(initrd_path):
                return jsonify({'error': '指定的 initrd 文件不存在'}), 400
        metadata['defaults']['initrd'] = data['initrd'] or None

    save_metadata(metadata)
    return jsonify({'success': True, 'defaults': metadata['defaults']})

@app.route('/api/grub-entries')
def list_grub_entries():
    """列出动态 GRUB 条目"""
    grub_config = os.path.join(BOOT_DIR, 'grub', 'grub.cfg')
    if not os.path.exists(grub_config):
        return jsonify([])

    with open(grub_config, 'r') as f:
        content = f.read()

    entries = []
    pattern = r'# <dynamic iso="([^"]+)">\n(menuentry\s+"([^"]+)"\s*\{[^}]*\})\n# </dynamic>'
    for match in re.finditer(pattern, content, re.DOTALL):
        entries.append({
            'iso': match.group(1),
            'title': match.group(3),
        })

    return jsonify(entries)

if __name__ == '__main__':
    # 创建必要的目录
    os.makedirs(os.path.join(BOOT_DIR, 'images', 'kernels'), exist_ok=True)
    os.makedirs(os.path.join(BOOT_DIR, 'images', 'initrds'), exist_ok=True)
    os.makedirs(os.path.join(BOOT_DIR, 'images', 'iso'), exist_ok=True)
    os.makedirs(os.path.join(BOOT_DIR, 'repos'), exist_ok=True)

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
