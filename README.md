# miao-infra

miao 生态共享基础设施：MySQL + Redis + Nacos。

供 [`miao-toolbox`](../miao-toolbox) 和 [`miao-ai`](../miao-ai) 共用。两个项目都通过外部网络 `miao-infra-net` 连接，不在自己的 compose 里定义数据库/缓存/配置中心容器。

## 服务清单

| 服务 | 镜像 | 容器名 | 网络 | 端口（内网/外网） |
|---|---|---|---|---|
| MySQL 8.4 | `mysql:8.4` | `miao-mysql` | `miao-infra-net` | `3306` / `33306` |
| Redis 7 | `redis:7-alpine` | `miao-redis` | `miao-infra-net` | `6379` / `16379` |
| Nacos 2.4 | `nacos/nacos-server:v2.4.3` | `miao-nacos` | `miao-infra-net` | `8848,9848` / `38848,39848` |

> Nacos 复用 `miao-mysql` 存储（`nacos_config` 库），不内嵌 Derby。

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
NACOS_AUTH_IDENTITY_KEY=nacos
NACOS_AUTH_IDENTITY_VALUE=nacos
NACOS_AUTH_TOKEN=YOUR_NACOS_AUTH_TOKEN_SECRET_BASE64
EOF
```
> `NACOS_AUTH_TOKEN` 用于服务端安全密钥，建议生成 32 字节以上 Base64 编码的随机串。`NACOS_AUTH_IDENTITY_KEY/VALUE` 用于 Nacos 服务间身份校验。
> Nacos 控制台默认账号密码为 `nacos/nacos`，首次登录后建议在 Web 控制台修改。

### 2. 启动

```bash
docker compose up -d
docker compose ps    # 应看到 miao-mysql + miao-redis + miao-nacos 都 healthy
```

### 3. 初始化业务库

只需在第一次部署时执行：

```bash
docker exec miao-mysql mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "
  CREATE DATABASE IF NOT EXISTS miao_toolbox CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE DATABASE IF NOT EXISTS miao_ai       CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE DATABASE IF NOT EXISTS nacos_config  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  GRANT ALL PRIVILEGES ON miao_toolbox.* TO 'miao'@'%';
  GRANT ALL PRIVILEGES ON miao_ai.*       TO 'miao'@'%';
  GRANT ALL PRIVILEGES ON nacos_config.*  TO 'miao'@'%';
  FLUSH PRIVILEGES;
"
```
> ⚠️ **`nacos_config` 库的表不会自动创建**。Nacos 在 mysql 模式下不会自动执行建表脚本，
> 必须手动导入官方 `mysql-schema.sql`，否则启动会报 `No Data Source set` / `dumpservice bean construction failure`。
> 初始化（只需一次）：
> ```bash
> docker exec miao-nacos cat /home/nacos/conf/mysql-schema.sql \
>   | docker exec -i miao-mysql mysql -u miao -p"$MYSQL_PASSWORD" nacos_config
> # 验证：USE nacos_config; SHOW TABLES; 应看到 config_info / users / roles 等 12 张表
> ```

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

连接串用容器名（`miao-mysql` / `miao-redis` / `miao-nacos`），不是 `localhost`：

```env
# miao-ai
DATABASE_URL=mysql+aiomysql://miao:PASSWORD@miao-mysql:3306/miao_ai?charset=utf8mb4
# miao-toolbox
MYSQL_URL=jdbc:mysql://miao-mysql:3306/miao_toolbox?useUnicode=true&characterEncoding=UTF-8&serverTimezone=Asia/Shanghai
REDIS_HOST=miao-redis
# Nacos 配置中心 / 注册中心（内网）
NACOS_SERVER_ADDR=miao-nacos:8848
NACOS_USERNAME=nacos
NACOS_PASSWORD=nacos
```

### 从外部 / 其他机器连接（非默认端口 + IP 白名单）

若业务应用部署在别的机器、需经公网访问本基础设施，使用宿主机发布的**非默认端口**
（容器名 + 默认端口 `3306/6379` 仅限同 `miao-infra-net` 网络内使用）：

```env
# miao-ai（外部访问）
DATABASE_URL=mysql+aiomysql://miao:PASSWORD@ts.yunmiao.site:33306/miao_ai?charset=utf8mb4
# miao-toolbox（外部访问）
MYSQL_URL=jdbc:mysql://ts.yunmiao.site:33306/miao_toolbox?useUnicode=true&characterEncoding=UTF-8&serverTimezone=Asia/Shanghai
REDIS_HOST=ts.yunmiao.site
REDIS_PORT=16379
# Nacos（外部访问）
NACOS_SERVER_ADDR=ts.yunmiao.site:38848
NACOS_USERNAME=nacos
NACOS_PASSWORD=nacos
```

> 这些端口（33306 / 16379 / 38848 / 39848）仅对白名单 IP 开放，不全公网暴露；具体放行在云安全组 /
> 服务器防火墙配置，不在此仓库内。
> Nacos 控制台通过 `http://ts.yunmiao.site:38848/nacos` 访问。

## 运维

```bash
# 看状态
docker compose ps

# 看日志
docker compose logs -f mysql
docker compose logs -f redis
docker compose logs -f nacos

# 备份 MySQL（含 nacos_config 库）
docker exec miao-mysql mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" \
  --all-databases --single-transaction > backup-$(date +%Y%m%d).sql

# 进入 MySQL
docker exec -it miao-mysql mysql -u miao -p miao_ai

# 进入 Nacos 容器
docker exec -it miao-nacos bash

# Nacos 控制台（内网）
open http://miao-nacos:8848/nacos

# 停机
docker compose down
```

## 升级 / 迁移

- **MySQL 小版本升级**：改 `image: mysql:8.4` 后的 tag，备份后 `docker compose pull && docker compose up -d`。
- **Redis 升级**：同理。
- **迁库**：在另一台机器起一套 miao-infra，mysqldump 导入，切换业务项目的 DATABASE_URL host。

## 设计原则

- **解耦基础设施与业务**：业务项目不关心 MySQL/Redis/Nacos 怎么起，infra 也不关心谁用它。
- **单例 MySQL**：不创建多个 MySQL 实例跟谁抢资源 / 端口；Nacos 也复用同一 MySQL 实例（`nacos_config` 库），符合单例原则。
- **数据持久化**：volume 名 `mysql-data` / `redis-data` / `nacos-logs` / `nacos-data`，绑本地存储。
- **健康检查**：所有服务都配 healthcheck，业务项目 `depends_on` 时可以 `condition: service_healthy`。
- **Nacos 鉴权**：默认开启（`NACOS_AUTH_ENABLE=true`），服务间调用需携带 `accessToken`，控制台需登录。
