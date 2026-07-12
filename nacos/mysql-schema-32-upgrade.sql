-- ============================================================
-- Nacos 2.4.x -> 3.2.x 增量迁移脚本（MySQL）
-- 目标版本：nacos/nacos-server:v3.2.2
-- 适用：当前 nacos_config 库已从 2.x 的 mysql-schema.sql 初始化过
--       （即已含 config_info / users / roles 等 12 张表，
--        且 config_info / his_config_info 已有 encrypted_data_key 列）
--
-- 执行时机：升级镜像标签之前（先迁库，再起 3.2.2 容器）
-- 幂等：列用 `ADD COLUMN IF NOT EXISTS` 语义需 MySQL 8.0.28+；
--       为兼容更低版本，这里用存储过程判断后执行，可重复运行不报错。
-- ============================================================

USE nacos_config;

DELIMITER $$

-- 通用：列不存在时才加
DROP PROCEDURE IF EXISTS `add_col_if_missing`$$
CREATE PROCEDURE `add_col_if_missing`(
  IN p_table VARCHAR(64),
  IN p_col   VARCHAR(64),
  IN p_def   TEXT
)
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = p_table
      AND COLUMN_NAME  = p_col
  ) THEN
    SET @sql = CONCAT('ALTER TABLE `', p_table, '` ADD COLUMN `', p_col, '` ', p_def);
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
  END IF;
END$$

DELIMITER ;

-- ---- 1. 配置表增量列（2.1.x 起已含 encrypted_data_key，这里仅补 his_config_info 三列）----
CALL add_col_if_missing('his_config_info', 'publish_type', "varchar(50) DEFAULT 'formal' COMMENT 'publish type gray or formal'");
CALL add_col_if_missing('his_config_info', 'gray_name',   "varchar(50) DEFAULT NULL COMMENT 'gray name'");
CALL add_col_if_missing('his_config_info', 'ext_info',    "longtext DEFAULT NULL COMMENT 'ext info'");

DROP PROCEDURE IF EXISTS `add_col_if_missing`;

-- ---- 2. 3.2.0 引入的 AI 模块新表（CREATE TABLE IF NOT EXISTS，幂等）----

CREATE TABLE IF NOT EXISTS `pipeline_execution` (
    `execution_id`  varchar(64)  NOT NULL COMMENT '执行ID',
    `resource_type` varchar(32)  NOT NULL COMMENT '资源类型',
    `resource_name` varchar(256) NOT NULL COMMENT '资源名称',
    `namespace_id`  varchar(128) DEFAULT NULL COMMENT '命名空间ID',
    `version`       varchar(64)  DEFAULT NULL COMMENT '版本',
    `status`        varchar(32)  NOT NULL COMMENT '执行状态',
    `pipeline`      longtext     NOT NULL COMMENT 'pipeline节点结果JSON',
    `create_time`   bigint(20)   NOT NULL COMMENT '创建时间',
    `update_time`   bigint(20)   NOT NULL COMMENT '修改时间',
    PRIMARY KEY (`execution_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='AI资源发布审核Pipeline执行记录';

CREATE TABLE IF NOT EXISTS `ai_resource` (
    `id` bigint(20) NOT NULL AUTO_INCREMENT COMMENT 'id',
    `gmt_create` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    `gmt_modified` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '修改时间',
    `name` varchar(256) NOT NULL COMMENT '资源名称',
    `type` varchar(32) NOT NULL COMMENT '资源类型',
    `c_desc` varchar(2048) DEFAULT NULL COMMENT '资源描述',
    `status` varchar(32) DEFAULT NULL COMMENT '资源状态',
    `namespace_id` varchar(128) NOT NULL DEFAULT '' COMMENT '命名空间ID',
    `biz_tags` varchar(1024) DEFAULT NULL COMMENT '业务标签',
    `ext` longtext DEFAULT NULL COMMENT '扩展信息(JSON)',
    `c_from` varchar(256) NOT NULL DEFAULT 'local' COMMENT '来源标识(导入/同步来源)',
    `version_info` longtext DEFAULT NULL COMMENT '版本信息(JSON)',
    `meta_version` bigint(20) NOT NULL DEFAULT 1 COMMENT '元数据版本(乐观锁)',
    `scope` varchar(16) NOT NULL DEFAULT 'PRIVATE' COMMENT '可见性: PUBLIC/PRIVATE',
    `owner` varchar(128) NOT NULL DEFAULT '' COMMENT '创建者用户名',
    `download_count` bigint(20) NOT NULL DEFAULT 0 COMMENT '下载次数',
    PRIMARY KEY (`id`),
    UNIQUE KEY `uk_ai_resource_ns_name_type` (`namespace_id`,`name`,`type`,`c_from`),
    KEY `idx_ai_resource_name` (`name`),
    KEY `idx_ai_resource_type` (`type`),
    KEY `idx_ai_resource_gmt_modified` (`gmt_modified`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='AI资源元数据表';

CREATE TABLE IF NOT EXISTS `ai_resource_version` (
    `id` bigint(20) NOT NULL AUTO_INCREMENT COMMENT 'id',
    `gmt_create` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    `gmt_modified` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '修改时间',
    `type` varchar(32) NOT NULL COMMENT '资源类型',
    `author` varchar(128) DEFAULT NULL COMMENT '作者',
    `name` varchar(256) NOT NULL COMMENT '资源名称',
    `c_desc` varchar(2048) DEFAULT NULL COMMENT '版本描述',
    `status` varchar(32) NOT NULL COMMENT '版本状态',
    `version` varchar(64) NOT NULL COMMENT '版本号',
    `namespace_id` varchar(128) NOT NULL DEFAULT '' COMMENT '命名空间ID',
    `storage` longtext DEFAULT NULL COMMENT '存储信息(JSON)',
    `publish_pipeline_info` longtext DEFAULT NULL COMMENT '发布流水线信息(JSON)',
    `download_count` bigint(20) NOT NULL DEFAULT 0 COMMENT '下载次数',
    PRIMARY KEY (`id`),
    UNIQUE KEY `uk_ai_resource_ver_ns_name_type_ver` (`namespace_id`,`name`,`type`,`version`),
    KEY `idx_ai_resource_ver_name` (`name`),
    KEY `idx_ai_resource_ver_status` (`status`),
    KEY `idx_ai_resource_ver_gmt_modified` (`gmt_modified`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='AI资源版本表';

-- 验证：应看到 13 张表
-- SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'nacos_config';
