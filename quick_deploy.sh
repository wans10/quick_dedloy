#!/bin/bash

set -e  # 遇到错误立即退出

echo "========================================="
echo "New-API 生产环境一键部署脚本"
echo "========================================="

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "请不要使用 root 用户运行此脚本"
        exit 1
    fi
}

# 检查系统类型
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        OS_VERSION=$VERSION_ID
    else
        print_error "无法检测操作系统类型"
        exit 1
    fi
    print_status "检测到操作系统: $OS $OS_VERSION"
}

# 检查 Docker 是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_warning "Docker 未安装，正在安装..."
        install_docker
    else
        print_status "Docker 已安装: $(docker --version)"
    fi
}

# 安装 Docker
install_docker() {
    if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
        sudo apt update
        sudo apt install -y curl
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker $USER
        rm get-docker.sh
    elif [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Red Hat"* ]]; then
        sudo yum install -y yum-utils curl
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker $USER
    else
        print_error "不支持的操作系统，请手动安装 Docker"
        exit 1
    fi
}

# 检查 Docker Compose 是否安装
check_docker_compose() {
    if ! command -v docker-compose &> /dev/null; then
        print_warning "Docker Compose 未安装，正在安装..."
        install_docker_compose
    else
        print_status "Docker Compose 已安装: $(docker-compose --version)"
    fi
}

# 安装 Docker Compose
install_docker_compose() {
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
}

# 创建项目目录
create_directories() {
    print_status "创建项目目录..."
    PROJECT_DIR="/opt/new-api"
    sudo mkdir -p $PROJECT_DIR
    sudo chown -R $USER:$USER $PROJECT_DIR
    cd $PROJECT_DIR
    
    mkdir -p {data,logs,ssl/server,ssl/client,mysql/conf.d,backups}
    chmod -R 755 .
}

# 生成随机密码
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# 创建环境变量文件
create_env_file() {
    print_status "创建环境变量文件..."
    
    MYSQL_ROOT_PASS=$(generate_password)
    MYSQL_USER_PASS=$(generate_password)
    REDIS_PASS=$(generate_password)
    SESSION_SECRET=$(openssl rand -base64 48 | tr -d "=+/" | cut -c1-32)
    
    cat > .env << EOF
# MySQL 配置
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASS
MYSQL_USER=newapi_user
MYSQL_PASSWORD=$MYSQL_USER_PASS

# Redis 配置
REDIS_PASSWORD=$REDIS_PASS

# 应用配置
SESSION_SECRET=$SESSION_SECRET
EOF

    print_status "环境变量文件已创建，密码已随机生成"
    print_warning "请保存以下密码信息："
    echo "MySQL Root 密码: $MYSQL_ROOT_PASS"
    echo "MySQL 用户密码: $MYSQL_USER_PASS"
    echo "Redis 密码: $REDIS_PASS"
}

# 创建 Docker Compose 文件
create_docker_compose() {
    print_status "创建 Docker Compose 文件..."
    
    cat > docker-compose.yml << 'EOF'
version: '3.4'

services:
  new-api:
    image: wans10/llm-api:latest
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "3000:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
      - ./ssl/client:/app/ssl/client:ro
    environment:
      - SQL_DSN=root:${MYSQL_ROOT_PASSWORD}@tcp(mysql:3306)/new-api?tls=custom&charset=utf8mb4&parseTime=True&loc=Local
      - REDIS_CONN_STRING=redis://redis
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - SESSION_SECRET=${SESSION_SECRET}
      - MYSQL_SSL_CA=/app/ssl/client/ca.pem
      - MYSQL_SSL_CERT=/app/ssl/client/client-cert.pem
      - MYSQL_SSL_KEY=/app/ssl/client/client-key.pem
    depends_on:
      - redis
      - mysql
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -o '\"success\":\\s*true' | awk -F: '{print $$2}'"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - new-api-network

  redis:
    image: redis:latest
    container_name: redis
    restart: always
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    environment:
      - REDIS_PASSWORD=${REDIS_PASSWORD}
    networks:
      - new-api-network

  mysql:
    image: mysql:8.4.5
    container_name: mysql
    restart: always
    ports:
      - "3306:3306"
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: new-api
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_SSL_CA: /etc/mysql/ssl/ca.pem
      MYSQL_SSL_CERT: /etc/mysql/ssl/server-cert.pem
      MYSQL_SSL_KEY: /etc/mysql/ssl/server-key.pem
    volumes:
      - mysql_data:/var/lib/mysql
      - ./ssl/server:/etc/mysql/ssl:ro
      - ./mysql/conf.d:/etc/mysql/conf.d:ro
    command: >
      --default-authentication-plugin=mysql_native_password
      --ssl-ca=/etc/mysql/ssl/ca.pem
      --ssl-cert=/etc/mysql/ssl/server-cert.pem
      --ssl-key=/etc/mysql/ssl/server-key.pem
      --require-secure-transport=ON
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --bind-address=0.0.0.0
    networks:
      - new-api-network

volumes:
  mysql_data:
  redis_data:

networks:
  new-api-network:
    driver: bridge
EOF
}

# 创建 MySQL 配置文件
create_mysql_config() {
    print_status "创建 MySQL 配置文件..."
    
    cat > mysql/conf.d/ssl.cnf << 'EOF'
[mysqld]
# SSL 配置
ssl-ca=/etc/mysql/ssl/ca.pem
ssl-cert=/etc/mysql/ssl/server-cert.pem
ssl-key=/etc/mysql/ssl/server-key.pem

# 强制使用 SSL 连接
require_secure_transport=ON

# 网络配置 - 允许外部访问
bind-address=0.0.0.0
port=3306

# 性能和安全优化（MySQL 8.4.5 优化）
max_connections=200
max_allowed_packet=64M
innodb_buffer_pool_size=1G
innodb_log_file_size=256M
innodb_flush_log_at_trx_commit=1
sync_binlog=1

# MySQL 8.4.5 新特性优化
innodb_redo_log_capacity=512M
innodb_doublewrite=ON
innodb_flush_method=O_DIRECT

# 字符集
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci

# 安全设置
skip-name-resolve
local-infile=0

# 外部访问安全配置
mysqlx-bind-address=0.0.0.0

# 连接超时设置
wait_timeout=3600
interactive_timeout=3600
EOF
}

# 生成 SSL 证书
generate_ssl_certs() {
    print_status "生成 SSL 证书..."
    
    # 生成 CA 私钥
    openssl genrsa 2048 > ssl/ca-key.pem
    
    # 生成 CA 证书
    openssl req -new -x509 -nodes -days 3650 -key ssl/ca-key.pem -out ssl/ca.pem -subj "/C=CN/ST=Beijing/L=Beijing/O=NewAPI/OU=IT/CN=MySQL-CA"
    
    # 生成服务器私钥
    openssl req -newkey rsa:2048 -nodes -days 3650 -keyout ssl/server/server-key.pem -out ssl/server/server-req.pem -subj "/C=CN/ST=Beijing/L=Beijing/O=NewAPI/OU=IT/CN=mysql"
    
    # 生成服务器证书
    openssl x509 -req -in ssl/server/server-req.pem -days 3650 -CA ssl/ca.pem -CAkey ssl/ca-key.pem -set_serial 01 -out ssl/server/server-cert.pem
    
    # 生成客户端私钥
    openssl req -newkey rsa:2048 -nodes -days 3650 -keyout ssl/client/client-key.pem -out ssl/client/client-req.pem -subj "/C=CN/ST=Beijing/L=Beijing/O=NewAPI/OU=IT/CN=client"
    
    # 生成客户端证书
    openssl x509 -req -in ssl/client/client-req.pem -days 3650 -CA ssl/ca.pem -CAkey ssl/ca-key.pem -set_serial 02 -out ssl/client/client-cert.pem
    
    # 复制 CA 证书到客户端目录
    cp ssl/ca.pem ssl/client/ca.pem
    cp ssl/ca.pem ssl/server/ca.pem
    
    # 设置权限
    chmod 600 ssl/ca-key.pem
    chmod 644 ssl/ca.pem
    chmod 600 ssl/server/server-key.pem
    chmod 644 ssl/server/server-cert.pem
    chmod 644 ssl/server/ca.pem
    chmod 600 ssl/client/client-key.pem
    chmod 644 ssl/client/client-cert.pem
    chmod 644 ssl/client/ca.pem
    
    # 清理临时文件
    rm ssl/server/server-req.pem ssl/client/client-req.pem
    
    print_status "SSL 证书生成完成"
}

# 配置防火墙
configure_firewall() {
    print_status "配置防火墙..."
    
    if command -v ufw &> /dev/null; then
        sudo ufw --force enable
        sudo ufw allow 22/tcp
        sudo ufw allow 3000/tcp
        sudo ufw allow 3306/tcp
        print_status "UFW 防火墙配置完成"
    elif command -v firewall-cmd &> /dev/null; then
        sudo systemctl start firewalld
        sudo systemctl enable firewalld
        sudo firewall-cmd --permanent --add-port=22/tcp
        sudo firewall-cmd --permanent --add-port=3000/tcp
        sudo firewall-cmd --permanent --add-port=3306/tcp
        sudo firewall-cmd --reload
        print_status "firewalld 防火墙配置完成"
    else
        print_warning "未检测到防火墙，请手动配置"
    fi
}

# 启动服务
start_services() {
    print_status "启动服务..."
    
    # 拉取镜像
    docker-compose pull
    
    # 启动服务
    docker-compose up -d
    
    print_status "等待服务启动..."
    sleep 30
    
    # 检查服务状态
    docker-compose ps
}

# 验证部署
verify_deployment() {
    print_status "验证部署..."
    
    # 检查容器状态
    if docker-compose ps | grep -q "Up"; then
        print_status "容器启动成功"
    else
        print_error "容器启动失败"
        docker-compose logs
        exit 1
    fi
    
    # 检查 API 服务
    sleep 10
    if curl -s http://localhost:3000/api/status | grep -q "success"; then
        print_status "API 服务正常"
    else
        print_warning "API 服务可能还在启动中，请稍后检查"
    fi
    
    # 检查 MySQL SSL
    if docker exec mysql mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'Ssl_cipher';" 2>/dev/null | grep -q "TLS"; then
        print_status "MySQL SSL 配置成功"
    else
        print_warning "MySQL SSL 状态未知，请手动检查"
    fi
}

# 创建管理脚本
create_management_scripts() {
    print_status "创建管理脚本..."
    
    # 备份脚本
    cat > backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/new-api/backups"
DATE=$(date +%Y%m%d_%H%M%S)

source .env

mkdir -p $BACKUP_DIR

# 备份 MySQL 数据
docker exec mysql mysqldump -u root -p${MYSQL_ROOT_PASSWORD} --single-transaction --routines --triggers new_api > $BACKUP_DIR/mysql_backup_$DATE.sql

# 备份配置文件
tar -czf $BACKUP_DIR/config_backup_$DATE.tar.gz docker-compose.yml .env mysql/ ssl/

# 删除7天前的备份
find $BACKUP_DIR -name "*.sql" -mtime +7 -delete
find $BACKUP_DIR -name "*.tar.gz" -mtime +7 -delete

echo "备份完成: $DATE"
EOF

    # 健康检查脚本
    cat > health_check.sh << 'EOF'
#!/bin/bash
LOG_FILE="/opt/new-api/logs/health_check.log"

# 检查容器状态
if ! docker-compose ps | grep -q "Up"; then
    echo "$(date): 容器异常，尝试重启" >> $LOG_FILE
    docker-compose restart
fi

# 检查 API 状态
if ! curl -s http://localhost:3000/api/status | grep -q "success"; then
    echo "$(date): API 服务异常" >> $LOG_FILE
fi

# 检查磁盘空间
DISK_USAGE=$(df /opt/new-api | tail -1 | awk '{print $5}' | sed 's/%//')
if [ $DISK_USAGE -gt 80 ]; then
    echo "$(date): 磁盘空间不足，使用率: ${DISK_USAGE}%" >> $LOG_FILE
fi
EOF

    chmod +x backup.sh health_check.sh
}

# 主函数
main() {
    print_status "开始部署 New-API..."
    
    check_root
    detect_os
    check_docker
    check_docker_compose
    create_directories
    create_env_file
    create_docker_compose
    create_mysql_config
    generate_ssl_certs
    configure_firewall
    start_services
    verify_deployment
    create_management_scripts
    
    print_status "========================================="
    print_status "部署完成！"
    print_status "========================================="
    echo
    print_status "访问信息："
    echo "  New-API 服务: http://$(hostname -I | awk '{print $1}'):3000"
    echo "  MySQL 服务: $(hostname -I | awk '{print $1}'):3306"
    echo
    print_status "管理命令："
    echo "  查看服务状态: docker-compose ps"
    echo "  查看日志: docker-compose logs -f"
    echo "  重启服务: docker-compose restart"
    echo "  停止服务: docker-compose down"
    echo "  备份数据: ./backup.sh"
    echo
    print_warning "重要提醒："
    echo "1. 请保存好生成的密码信息"
    echo "2. 建议修改默认密码"
    echo "3. 配置定时备份任务"
    echo "4. 定期检查服务状态"
    echo
    print_status "如需重新登录以应用 Docker 组权限，请执行: newgrp docker"
}

# 捕获中断信号
trap 'print_error "部署被中断"; exit 1' INT

# 检查参数
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "New-API 生产环境一键部署脚本"
    echo
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -h, --help     显示帮助信息"
    echo "  --skip-docker  跳过 Docker 安装检查"
    echo "  --no-firewall  跳过防火墙配置"
    echo
    exit 0
fi

# 执行主函数
main "$@"
