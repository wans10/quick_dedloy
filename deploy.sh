#!/bin/bash

# Ubuntu 24 New-API 生产环境部署脚本
# 执行前请确保已安装 Docker 和 Docker Compose

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查系统环境
check_environment() {
    echo_info "检查系统环境..."
    
    # 检查是否为 root 用户或有 sudo 权限
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        echo_error "需要 root 权限或 sudo 权限"
        exit 1
    fi
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        echo_error "Docker 未安装"
        exit 1
    fi
    
    # 检查 Docker Compose
    if ! docker compose version &> /dev/null; then
        echo_error "Docker Compose 未安装或版本过低"
        exit 1
    fi
    
    # 检查必要工具
    for tool in openssl curl jq; do
        if ! command -v $tool &> /dev/null; then
            echo_info "安装 $tool..."
            sudo apt update -qq
            sudo apt install -y $tool
        fi
    done
    
    echo_info "环境检查完成"
}

# 创建项目目录结构
create_directories() {
    echo_info "创建项目目录结构..."
    
    # 设置项目根目录
    PROJECT_ROOT="/opt/new-api-prod"
    
    # 创建所需目录
    sudo mkdir -p $PROJECT_ROOT/{data,logs,mysql/{conf.d,init,backup},redis,ssl/{server,client,ca},nginx,scripts}
    
    # 设置目录权限
    sudo chown -R $USER:$USER $PROJECT_ROOT
    
    cd $PROJECT_ROOT
    echo_info "项目目录创建完成: $PROJECT_ROOT"
}

# 生成 SSL 证书
generate_ssl_certificates() {
    echo_info "生成 SSL 证书..."
    
    cd ssl/ca
    
    # 生成 CA 私钥和证书
    echo_info "生成 CA 证书..."
    openssl genrsa -out ca-key.pem 4096 2>/dev/null
    openssl req -new -x509 -days 3650 -key ca-key.pem -out ca.pem \
        -subj "/C=CN/ST=Shanghai/L=Shanghai/O=NewAPI/CN=MySQL-CA" 2>/dev/null
    
    # 生成服务端证书
    echo_info "生成服务端证书..."
    cd ../server
    openssl genrsa -out server-key.pem 4096 2>/dev/null
    openssl req -new -key server-key.pem -out server-req.pem \
        -subj "/C=CN/ST=Shanghai/L=Shanghai/O=NewAPI/CN=mysql" 2>/dev/null
    openssl x509 -req -in server-req.pem -CA ../ca/ca.pem -CAkey ../ca/ca-key.pem \
        -CAcreateserial -out server-cert.pem -days 3650 2>/dev/null
    cp ../ca/ca.pem .
    rm server-req.pem
    
    # 生成客户端证书
    echo_info "生成客户端证书..."
    cd ../client
    openssl genrsa -out client-key.pem 4096 2>/dev/null
    openssl req -new -key client-key.pem -out client-req.pem \
        -subj "/C=CN/ST=Shanghai/L=Shanghai/O=NewAPI/CN=mysql-client" 2>/dev/null
    openssl x509 -req -in client-req.pem -CA ../ca/ca.pem -CAkey ../ca/ca-key.pem \
        -CAcreateserial -out client-cert.pem -days 3650 2>/dev/null
    cp ../ca/ca.pem .
    rm client-req.pem
    
    # 设置证书权限
    cd $PROJECT_ROOT
    chmod 600 ssl/*/private-key.pem ssl/*/*-key.pem 2>/dev/null || chmod 600 ssl/*/*-key.pem
    chmod 644 ssl/*/*.pem
    
    echo_info "SSL 证书生成完成"
}

# 生成配置文件
generate_configs() {
    echo_info "生成配置文件..."
    
    cd $PROJECT_ROOT
    
    # 生成随机密码
    MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
    MYSQL_PASSWORD=$(openssl rand -base64 32)
    REDIS_PASSWORD=$(openssl rand -base64 32)
    SESSION_SECRET=$(openssl rand -hex 32)
    
    # 创建 .env 文件
    cat > .env << EOF
# MySQL 配置
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_USER=newapi
MYSQL_PASSWORD=$MYSQL_PASSWORD

# Redis 配置
REDIS_PASSWORD=$REDIS_PASSWORD

# New-API 配置
SESSION_SECRET=$SESSION_SECRET

# 时区
TZ=Asia/Shanghai

# 备份配置
BACKUP_RETENTION_DAYS=7
EOF

    # 创建 MySQL 配置文件
    cat > mysql/conf.d/mysql.cnf << 'EOF'
[mysqld]
# 基础配置
bind-address = 0.0.0.0
port = 3306
default-time-zone = '+08:00'
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# SSL 配置
ssl-ca = /etc/mysql/ssl/ca.pem
ssl-cert = /etc/mysql/ssl/server-cert.pem
ssl-key = /etc/mysql/ssl/server-key.pem
require-secure-transport = ON
tls-version = TLSv1.2,TLSv1.3

# 性能优化
innodb-buffer-pool-size = 512M
innodb-log-file-size = 128M
innodb-flush-log-at-trx-commit = 2
innodb-file-per-table = 1
innodb-open-files = 1000

# 连接配置
max-connections = 200
max-connect-errors = 100000
max-allowed-packet = 64M
interactive-timeout = 28800
wait-timeout = 28800

# 日志配置
slow-query-log = 1
slow-query-log-file = /var/lib/mysql/slow.log
long-query-time = 2
log-error = /var/lib/mysql/error.log

# 二进制日志
binlog-expire-logs-seconds = 259200
max-binlog-size = 100M

# 安全配置
local-infile = 0
skip-show-database

[mysql]
default-character-set = utf8mb4
ssl-mode = REQUIRED

[client]
default-character-set = utf8mb4
ssl-mode = REQUIRED
EOF

    # 创建 MySQL 初始化脚本
    cat > mysql/init/01-setup.sql << EOF
-- 创建应用用户
CREATE USER IF NOT EXISTS 'newapi'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' REQUIRE SSL;
GRANT SELECT, INSERT, UPDATE, DELETE ON \`new-api\`.* TO 'newapi'@'%';

-- 创建外部访问用户
CREATE USER IF NOT EXISTS 'external'@'34.169.198.216' IDENTIFIED BY '$MYSQL_PASSWORD' REQUIRE SSL;
GRANT SELECT, INSERT, UPDATE, DELETE ON \`new-api\`.* TO 'external'@'34.169.198.216';

-- 创建监控用户
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY 'monitor_${MYSQL_PASSWORD:0:16}' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';

-- 刷新权限
FLUSH PRIVILEGES;
EOF

    # 创建 Redis 配置文件
    cat > redis/redis.conf << 'EOF'
# 网络配置
bind 0.0.0.0
port 6379
protected-mode yes
tcp-backlog 511
timeout 300
tcp-keepalive 300

# 内存配置
maxmemory 256mb
maxmemory-policy allkeys-lru
maxmemory-samples 5

# 持久化配置
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /data

# AOF 配置
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# 日志配置
loglevel notice
logfile ""

# 客户端配置
maxclients 10000

# 慢日志配置
slowlog-log-slower-than 10000
slowlog-max-len 128

# 延迟监控
latency-monitor-threshold 100
EOF

    # 创建备份脚本
    cat > scripts/backup.sh << 'EOF'
#!/bin/bash

# 加载环境变量
source /opt/new-api-prod/.env

# 配置
BACKUP_DIR="/opt/new-api-backup"
DATE=$(date +%Y%m%d_%H%M%S)

# 创建备份目录
mkdir -p $BACKUP_DIR/{mysql,redis,data}

echo "开始备份 - $DATE"

# 备份 MySQL
docker exec mysql mysqldump \
  -u root -p$MYSQL_ROOT_PASSWORD \
  --ssl-mode=REQUIRED \
  --single-transaction \
  --routines \
  --triggers \
  --all-databases > $BACKUP_DIR/mysql/backup_$DATE.sql

if [ $? -eq 0 ]; then
    echo "MySQL 备份完成"
else
    echo "MySQL 备份失败"
    exit 1
fi

# 备份 Redis
docker exec redis redis-cli --rdb /data/dump_$DATE.rdb
docker cp redis:/data/dump_$DATE.rdb $BACKUP_DIR/redis/
docker exec redis rm /data/dump_$DATE.rdb

# 备份应用数据
cp -r /opt/new-api-prod/data $BACKUP_DIR/data/data_$DATE

# 压缩备份
tar -czf $BACKUP_DIR/full_backup_$DATE.tar.gz -C $BACKUP_DIR mysql redis data
rm -rf $BACKUP_DIR/{mysql,redis,data}

# 清理旧备份
find $BACKUP_DIR -name "full_backup_*.tar.gz" -mtime +$BACKUP_RETENTION_DAYS -delete

echo "备份完成: $BACKUP_DIR/full_backup_$DATE.tar.gz"
EOF

    # 创建监控脚本
    cat > scripts/monitor.sh << 'EOF'
#!/bin/bash

PROJECT_ROOT="/opt/new-api-prod"
cd $PROJECT_ROOT

echo "=== $(date) ==="

# 检查服务状态
check_service() {
    local service=$1
    if docker compose ps $service | grep -q "running"; then
        echo "✅ $service is running"
        return 0
    else
        echo "❌ $service is not running"
        return 1
    fi
}

# 检查所有服务
echo "=== Service Status Check ==="
SERVICES_OK=true
for service in new-api mysql redis; do
    if ! check_service $service; then
        SERVICES_OK=false
    fi
done

# 检查应用健康状态
echo "=== Application Health ==="
if curl -s --max-time 10 http://localhost:3000/api/status | grep -q '"success":.*true'; then
    echo "✅ API health check passed"
else
    echo "❌ API health check failed"
    SERVICES_OK=false
fi

# 检查磁盘空间
echo "=== Disk Usage ==="
df -h | grep -E "(/$|mysql|redis)" | while read line; do
    usage=$(echo $line | awk '{print $5}' | sed 's/%//')
    if [ "$usage" -gt 85 ]; then
        echo "⚠️  High disk usage: $line"
    else
        echo "✅ $line"
    fi
done

# 如果有问题，可以在这里添加告警通知
if [ "$SERVICES_OK" = false ]; then
    echo "🚨 检测到服务异常，请及时处理"
    # 这里可以添加邮件或 webhook 通知
fi

echo "===================="
EOF

    chmod +x scripts/*.sh
    
    echo_info "配置文件生成完成"
    echo_warn "生成的密码信息已保存到 .env 文件，请妥善保管！"
}

# 配置防火墙
configure_firewall() {
    echo_info "配置防火墙..."
    
    # Ubuntu 24 默认使用 ufw
    if command -v ufw &> /dev/null; then
        # 检查 ufw 是否启用
        if ! sudo ufw status | grep -q "Status: active"; then
            echo_warn "UFW 防火墙未启用，正在启用..."
            sudo ufw --force enable
        fi
        
        # 确保 SSH 连接不被阻断
        sudo ufw allow ssh
        
        # 开放必要端口
        sudo ufw allow 80/tcp comment 'HTTP'
        sudo ufw allow 443/tcp comment 'HTTPS'
        sudo ufw allow 3000/tcp comment 'New-API'
        
        # 允许特定 IP 访问 MySQL
        sudo ufw allow from 34.169.198.216 to any port 3306 comment 'MySQL External Access'
        
        echo_info "防火墙配置完成"
        sudo ufw status numbered
    else
        echo_warn "未找到 ufw，请手动配置防火墙"
    fi
}

# 部署应用
deploy_application() {
    echo_info "部署应用..."
    
    cd $PROJECT_ROOT
    
    # 拉取镜像
    echo_info "拉取 Docker 镜像..."
    docker compose pull
    
    # 启动服务
    echo_info "启动服务..."
    docker compose up -d
    
    # 等待服务启动
    echo_info "等待服务启动..."
    sleep 30
    
    # 检查服务状态
    echo_info "检查服务状态..."
    docker compose ps
}

# 验证部署
verify_deployment() {
    echo_info "验证部署..."
    
    cd $PROJECT_ROOT
    
    # 检查容器状态
    echo_info "检查容器状态..."
    if ! docker compose ps | grep -q "Up"; then
        echo_error "容器启动失败"
        docker compose logs
        return 1
    fi
    
    # 等待服务完全启动
    echo_info "等待服务完全启动..."
    for i in {1..30}; do
        if curl -s http://localhost:3000/api/status >/dev/null 2>&1; then
            break
        fi
        if [ $i -eq 30 ]; then
            echo_error "服务启动超时"
            return 1
        fi
        sleep 2
    done
    
    # 测试 API 健康检查
    echo_info "测试 API 健康检查..."
    if curl -s http://localhost:3000/api/status | grep -q '"success":.*true'; then
        echo_info "✅ API 健康检查通过"
    else
        echo_error "❌ API 健康检查失败"
        return 1
    fi
    
    # 测试 MySQL SSL 连接
    echo_info "测试 MySQL SSL 连接..."
    if docker exec mysql mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SHOW STATUS LIKE 'Ssl_cipher';" 2>/dev/null | grep -q "Ssl_cipher"; then
        echo_info "✅ MySQL SSL 连接正常"
    else
        echo_warn "⚠️  MySQL SSL 连接测试失败，请检查配置"
    fi
    
    echo_info "部署验证完成"
}

# 设置定时任务
setup_crontab() {
    echo_info "设置定时任务..."
    
    # 创建日志目录
    sudo mkdir -p /var/log/new-api
    
    # 添加 crontab 任务
    (crontab -l 2>/dev/null; echo "# New-API 自动备份和监控") | crontab -
    (crontab -l 2>/dev/null; echo "0 2 * * * $PROJECT_ROOT/scripts/backup.sh >> /var/log/new-api/backup.log 2>&1") | crontab -
    (crontab -l 2>/dev/null; echo "0 * * * * $PROJECT_ROOT/scripts/monitor.sh >> /var/log/new-api/monitor.log 2>&1") | crontab -
    
    echo_info "定时任务设置完成"
    echo_info "备份时间: 每天凌晨 2:00"
    echo_info "监控检查: 每小时一次"
}

# 显示部署信息
show_deployment_info() {
    echo_info "部署完成！"
    echo ""
    echo "=========================="
    echo "部署信息:"
    echo "=========================="
    echo "项目目录: $PROJECT_ROOT"
    echo "应用访问: http://$(hostname -I | awk '{print $1}'):3000"
    echo "MySQL 端口: 3306 (SSL 必需)"
    echo ""
    echo "重要文件:"
    echo "- 环境变量: $PROJECT_ROOT/.env"
    echo "- Docker 配置: $PROJECT_ROOT/docker-compose.yml"
    echo "- 备份脚本: $PROJECT_ROOT/scripts/backup.sh"
    echo "- 监控脚本: $PROJECT_ROOT/scripts/monitor.sh"
    echo ""
    echo "常用命令:"
    echo "- 查看服务状态: cd $PROJECT_ROOT && docker compose ps"
    echo "- 查看日志: cd $PROJECT_ROOT && docker compose logs -f"
    echo "- 重启服务: cd $PROJECT_ROOT && docker compose restart"
    echo "- 停止服务: cd $PROJECT_ROOT && docker compose down"
    echo ""
    echo "⚠️  重要提醒:"
    echo "1. 请妥善保管 .env 文件中的密码信息"
    echo "2. 定期检查备份是否正常执行"
    echo "3. 建议设置 SSL 证书定期更新"
    echo "4. 生产环境建议配置域名和 HTTPS"
    echo "=========================="
}

# 主函数
main() {
    echo_info "开始部署 New-API 生产环境..."
    echo_info "系统: $(lsb_release -d | cut -f2)"
    echo_info "Docker: $(docker --version)"
    echo_info "Docker Compose: $(docker compose version --short)"
    echo ""
    
    check_environment
    create_directories
    generate_ssl_certificates
    generate_configs
    configure_firewall
    deploy_application
    verify_deployment
    setup_crontab
    show_deployment_info
    
    echo_info "部署完成！🎉"
}

# 执行主函数
main "$@"
