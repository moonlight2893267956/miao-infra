# miao-infra

miao 生态共享基础设施：MySQL + Redis。

供 [`miao-toolbox`](../miao-toolbox) 和 [`miao-ai`](../miao-ai) 共用。两个项目都通过外部网络 `miao-infra-net` 连接，不在自己的 compose 里定义数据库/缓存容器。

## 服务清单

| 服务 | 镜像 | 容器名 | 网络 |
|---|---|---|---|
| MySQL 8.4 | `mysql:8.4` | `miao-mysql` | `miao-infra-net` |
| Redis 7 | `redis:7-alpine` | `miao-redis` | `miao-infra-net` |

固定网络名 `miao-infra-net`，两个项目都引用它。

## 部署

### 1. 写 `.env`

```bash
cd ~/apps/miao-infra
cat > .env <<EOF
MYSQL_ROOT_PASSWORD=YOUR_ROOT_PASSWORD
MYSQL_USER=miao
MYSQL_PASSWORD=YOUR_MIAO_PASSWORD
REDIS_PASSWORD=YOUR_REDIS_PASSWORD
EOF
```

### 2. 启动

```bash
docker compose up -d
docker compose ps    # 应看到 miao-mysql + miao-redis 都 healthy
```

### 3. 初始化业务库

只需在第一次部署时执行：

```bash
docker exec miao-mysql mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "
  CREATE DATABASE IF NOT EXISTS miao_toolbox CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE DATABASE IF NOT EXISTS miao_ai       CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  GRANT ALL PRIVILEGES ON miao_toolbox.* TO 'miao'@'%';
  GRANT ALL PRIVILEGES ON miao_ai.*       TO 'miao'@'%';
  FLUSH PRIVILEGES;
"
```

业务项目自己负责 alembic / Flyway 迁移。

## 接入方接入方式

业务项目（如 miao-ai）接入时：

```yaml
# docker-compose.prod.yml
services:
  backend:
    networks:
      - miao-infra-net

networks:
  miao-infra-net:
    external: true
    name: miao-infra-net
```

连接串用容器名（`miao-mysql` / `miao-redis`），不是 `localhost`：

```env
# miao-ai
DATABASE_URL=mysql+aiomysql://miao:PASSWORD@miao-mysql:3306/miao_ai?charset=utf8mb4
# miao-toolbox
MYSQL_URL=jdbc:mysql://miao-mysql:3306/miao_toolbox?useUnicode=true&characterEncoding=UTF-8&serverTimezone=Asia/Shanghai
REDIS_HOST=miao-redis
```

## 运维

```bash
# 看状态
docker compose ps

# 看日志
docker compose logs -f mysql
docker compose logs -f redis

# 备份 MySQL
docker exec miao-mysql mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" \
  --all-databases --single-transaction > backup-$(date +%Y%m%d).sql

# 进入 MySQL
docker exec -it miao-mysql mysql -u miao -p miao_ai

# 停机
docker compose down
```

## 升级 / 迁移

- **MySQL 小版本升级**：改 `image: mysql:8.4` 后的 tag，备份后 `docker compose pull && docker compose up -d`。
- **Redis 升级**：同理。
- **迁库**：在另一台机器起一套 miao-infra，mysqldump 导入，切换业务项目的 DATABASE_URL host。

## 设计原则

- **解耦基础设施与业务**：业务项目不关心 MySQL/Redis 怎么起，infra 也不关心谁用它。
- **单例 MySQL**：不创建多个 MySQL 实例跟谁抢资源 / 端口。
- **数据持久化**：volume 名 `mysql-data` / `redis-data`，绑本地存储。
- **健康检查**：两个服务都配 healthcheck，业务项目 `depends_on` 时可以 `condition: service_healthy`。
