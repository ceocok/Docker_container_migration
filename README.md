# Docker 容器一键迁移脚本

脚本地址
https://raw.githubusercontent.com/ceocok/c.cococ/refs/heads/main/Docker_container_migration.sh
该脚本可在两台 Linux 服务器间 全自动备份 & 恢复 所有 Docker 容器（含卷数据），并自带临时下载服务器，无须手动传输文件。
| 功能       | 说明                                                       |
| -------- | -------------------------------------------------------- |
| 一键备份     | 自动生成 `docker run` 恢复脚本，打包容器卷并启动临时下载服务器（端口 **8889**）。     |
| 一键恢复     | 远程拉取备份包并恢复全部容器，成功后自动 `docker ps`，显示绿色 “✅容器恢复成功”。         |
| 无侵入      | 不修改现有容器配置，仅生成并执行同等参数的 `docker run`。                      |
| Nginx 保护 | 备份时自动备份原始 `/etc/nginx/sites-available/default`，退出后可一键恢复。 |


⚙️ 前置条件

root 权限（或 sudo）。
源、目标服务器均已安装 Docker。脚本会自动检测并在缺失时提示安装。
源服务器需开放 TCP 8889（备份包下载端口）。

🚀 快速开始

1. 在两台服务器上下载脚本

任意目录均可
```
curl -O https://raw.githubusercontent.com/ceocok/c.cococ/refs/heads/main/Docker_container_migration.sh
chmod +x Docker_container_migration.sh
./Docker_container_migration.sh
```
2. 在 源服务器 备份
```
./Docker_container_migration.sh
```
 选择 1 → 1

执行完毕后，终端会输出类似：
下载地址: http://<源服务器IP>:8889/docker_full_backup.tar.gz
⚠️ 备份过程中 源服务器会临时占用 Nginx 端口 8889，请勿中断脚本。

3. 在 目标服务器 恢复
```
sudo ./Docker_container_migration.sh
```
 选择 1 → 2
 按提示输入“源服务器 IP”

脚本将自动下载备份包、还原容器并在完成后显示：
✅<容器名> 容器恢复成功！
...
--- ✅ 所有容器已成功恢复！ ---

随后自动执行 docker ps 供你核对。

4. （可选）恢复源服务器原 Nginx 配置

备份完成后，如需立即还原原有 80/443 站点，只需在源服务器再次运行脚本并选：
```
2. 恢复原始 Nginx 配置
```
   
📄 许可证

本仓库除另行声明外，均采用 MIT License。随意使用、修改与分发，但请保留原作者信息。
