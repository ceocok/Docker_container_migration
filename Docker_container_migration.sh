#!/bin/bash

# --- 定义颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
Blue="\033[36m"
YELLOW='\033[1;33m'
Font="\033[0m"
NC='\033[0m'

# --- 脚本必须以 root 权限运行 ---
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 此脚本必须以 root 权限运行。${NC}" >&2
    echo -e "${YELLOW}请尝试使用 'sudo ./docker_manager.sh'${NC}"
    exit 1
  fi
}

# --- 按需检查并安装依赖的函数 ---
ensure_packages() {
  local PKG_MANAGER=""
  if [ -f /etc/os-release ]; then . /etc/os-release; OS_ID=$ID; else echo -e "${RED}无法检测到操作系统。${NC}" >&2; exit 1; fi
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then PKG_MANAGER="apt-get"; elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "fedora" ]]; then PKG_MANAGER="yum"; if ! command -v yum &> /dev/null; then PKG_MANAGER="dnf"; fi; else echo -e "${RED}不支持的操作系统: $OS_ID ${NC}" >&2; exit 1; fi
  if [[ $PKG_MANAGER == "apt-get" ]]; then echo "正在更新软件包列表..."; sudo $PKG_MANAGER update > /dev/null; fi

  for pkg in "$@"; do
    if ! command -v "$pkg" &> /dev/null; then
      echo -e "${YELLOW}未找到命令: $pkg, 正在安装...${NC}"
      if [ "$pkg" == "docker" ]; then
        curl -fsSL https://get.docker.com -o get-docker.sh; sudo sh get-docker.sh; rm get-docker.sh
        if [ $? -ne 0 ]; then echo -e "${RED}Docker 安装失败。${NC}" >&2; exit 1; fi
        sudo systemctl start docker && sudo systemctl enable docker
      else
        sudo $PKG_MANAGER install -y "$pkg"
        if [ $? -ne 0 ]; then echo -e "${RED}依赖 $pkg 安装失败。${NC}" >&2; exit 1; fi
      fi
      echo -e "${GREEN}$pkg 安装成功。${NC}"
    else
      echo -e "${GREEN}依赖 $pkg 已安装。${NC}"
    fi
  done
}

### ========================================================= ###
###            ★ 安全的 Nginx 操作 ★
### ========================================================= ###

NGINX_TEMP_CONF="/etc/nginx/sites-available/docker-migration-server.conf"
NGINX_ENABLED_LINK="/etc/nginx/sites-enabled/docker-migration-server.conf"

# --- 捕获退出信号，确保临时文件被清理 ---
cleanup_on_exit() {
    echo -e "\n${YELLOW}捕获到退出信号，正在执行清理...${NC}"
    restore_nginx_config
    exit 1
}
trap cleanup_on_exit INT TERM

# --- ★ 通用功能: 启动 Nginx 临时下载服务器 ★ ---
setup_nginx_for_download() {
  if [ -f "$NGINX_TEMP_CONF" ]; then
    echo -e "${GREEN}Nginx 临时下载服务器配置已存在。${NC}"; return 0
  fi
  echo -e "${YELLOW}正在配置 Nginx 临时文件服务器...${NC}"
read -r -d '' NGX_DL_CONF <<'EOF'
server {
    listen 8889;
    server_name _;
    root /var/www/html;
    autoindex on;
    access_log off;
    location / {
        try_files $uri =404;
    }
}
EOF
  echo "$NGX_DL_CONF" > "$NGINX_TEMP_CONF"
  ln -s "$NGINX_TEMP_CONF" "$NGINX_ENABLED_LINK"
  mkdir -p /var/www/html/
  
  echo "正在测试并重载 Nginx..."
  nginx -t
  if [ $? -ne 0 ]; then
    echo -e "${RED}Nginx 配置测试失败！请手动检查。正在移除临时配置...${NC}"
    rm -f "$NGINX_TEMP_CONF" "$NGINX_ENABLED_LINK"
    return 1
  fi
  systemctl reload nginx
  if [ $? -ne 0 ]; then
    echo -e "${RED}重载 Nginx 失败！可能是端口冲突。请检查是否有其他服务占用了 8889 端口。${NC}"
    rm -f "$NGINX_TEMP_CONF" "$NGINX_ENABLED_LINK"
    return 1
  fi
  echo -e "${GREEN}Nginx 已成功配置在 8889 端口用于文件下载。${NC}"; return 0
}

# --- ★ 通用功能: 恢复原始 Nginx 配置 ★ ---
restore_nginx_config() {
    if [ -f "$NGINX_TEMP_CONF" ]; then
        echo -e "${YELLOW}检测到临时 Nginx 配置，正在移除...${NC}"
        rm -f "$NGINX_TEMP_CONF" "$NGINX_ENABLED_LINK"
        echo "正在测试并重载 Nginx..."
        nginx -t && systemctl reload nginx
        if [ $? -ne 0 ]; then
            echo -e "${RED}恢复 Nginx 配置失败，请手动检查 'nginx -t' 和 'systemctl status nginx'。${NC}"
        else
            echo -e "${GREEN}Nginx 临时配置已成功移除。${NC}"
        fi
    else
        echo -e "${YELLOW}未找到由本脚本创建的 Nginx 临时配置文件，无需恢复。${NC}"
    fi
}

# ==================================================
#           ★ 功能核心: Docker容器迁移 ★
# ==================================================
check_runlike() {
    echo "检查 runlike 工具..."
    if ! docker image inspect assaflavie/runlike:latest >/dev/null 2>&1; then
        echo -e "${YELLOW}runlike 镜像不存在，正在从 Docker Hub 拉取...${NC}"
        docker pull assaflavie/runlike:latest
        if [ $? -ne 0 ]; then
            echo -e "${RED}拉取 runlike 镜像失败，请检查 Docker 环境和网络。${NC}"
            return 1
        fi
        echo -e "${GREEN}runlike 镜像拉取成功。${NC}"
    else
        echo -e "${GREEN}runlike 镜像已存在。${NC}"
    fi
    return 0
}

full_docker_backup() {
    echo -e "\n${YELLOW}--- 开始Docker容器备份 ---${NC}"
    ensure_packages "docker" "tar" "nginx"
    check_runlike || return 1

    local BACKUP_DIR="docker_full_backup_$$"
    local RESTORE_SCRIPT_NAME="restore_all_containers.sh"
    local VOLUME_PATHS_FILE="volume_paths.txt"
    mkdir "$BACKUP_DIR"

    local CONTAINERS
    CONTAINERS=$(docker ps --format '{{.Names}}')
    if [ -z "$CONTAINERS" ]; then
        echo -e "${RED}错误: 未找到任何正在运行的 Docker 容器。${NC}"; rm -rf "$BACKUP_DIR"; return 1
    fi

    echo "发现以下正在运行的容器:"
    echo -e "${GREEN}$CONTAINERS${NC}"

    # 初始化恢复脚本
    {
        echo "#!/bin/bash"
        echo "# Docker 容器恢复脚本 (自动生成)"
        echo ""
        echo "GREEN='\\033[0;32m'; RED='\\033[0;31m'; YELLOW='\\033[1;33m'; NC='\\033[0m'"
        echo "# 获取脚本所在的绝对路径"
        echo "MIGRATION_DIR=\$(cd \"\$(dirname \"\$0\")\" && pwd)"
        echo "echo \"数据卷的恢复目录是: \${MIGRATION_DIR}\""
    } > "${BACKUP_DIR}/${RESTORE_SCRIPT_NAME}"

    for container in $CONTAINERS; do
        echo -e "\n${YELLOW}--- 正在处理容器: $container ---${NC}"
        echo "1. 生成 'docker run' 命令..."
        local RUN_COMMAND
        RUN_COMMAND=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock assaflavie/runlike "$container")
        
        ### ★ 并为恢复做准备 ###
        local CLEANED_COMMAND
        CLEANED_COMMAND=$(echo "$RUN_COMMAND" | sed -E 's/--hostname=[^ ]+ //g; s/--mac-address=[^ ]+ //g; s/--name=[^ ]+ //g' | sed 's/ -d / -d --name '"$container"' /')

        # 修改命令中的-v参数，使其指向新服务器上的恢复目录
        local MODIFIED_COMMAND
        MODIFIED_COMMAND=$(echo "$CLEANED_COMMAND" | sed -E "s|-v ([^:]+):|-v \${MIGRATION_DIR}\\1:|g")

        {
            echo ""
            echo "echo -e \"\n--- 正在恢复容器: $container ---\""
            echo "echo \"使用以下命令恢复:\""
            echo "echo \"$MODIFIED_COMMAND\"" # 打印用于调试
            echo "CID=\$($MODIFIED_COMMAND)"
            echo "if [ -n \"\$CID\" ]; then"
            echo "    echo -e \"\${GREEN}容器 $container 恢复成功！ (ID: \$(echo \$CID | cut -c1-12)) \${NC}\""
            echo "else"
            echo "    echo -e \"\${RED}容器 $container 恢复失败，请检查 Docker 日志！\${NC}\"; exit 1"
            echo "fi"
        } >> "${BACKUP_DIR}/${RESTORE_SCRIPT_NAME}"

        echo "2. 提取挂载卷路径..."
        docker inspect "$container" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' >> "${BACKUP_DIR}/${VOLUME_PATHS_FILE}.tmp"
    done

    sort -u "${BACKUP_DIR}/${VOLUME_PATHS_FILE}.tmp" > "${BACKUP_DIR}/${VOLUME_PATHS_FILE}"
    rm "${BACKUP_DIR}/${VOLUME_PATHS_FILE}.tmp"

    echo -e "\n${YELLOW}--- 开始打包数据卷和恢复脚本 ---${NC}"
    # 使用 absolute-names 来保留从 / 开始的完整路径结构
    tar -czvf docker_full_backup.tar.gz --absolute-names -C "${BACKUP_DIR}" "${RESTORE_SCRIPT_NAME}" -C / -T "${BACKUP_DIR}/${VOLUME_PATHS_FILE}"
    if [ $? -ne 0 ]; then echo -e "${RED}打包失败!${NC}"; rm -rf "$BACKUP_DIR"; return 1; fi
    rm -rf "$BACKUP_DIR"
    echo -e "${GREEN}打包成功！ 文件名: docker_full_backup.tar.gz${NC}"

    echo "配置下载服务器..."
    setup_nginx_for_download || return 1
    mv docker_full_backup.tar.gz /var/www/html/docker_full_backup.tar.gz

    local SERVER_IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}--- ✅  Docker容器 备份完成！ ---${NC}"
    echo -e "请在${YELLOW}新服务器${NC}上运行此脚本并选择恢复选项。"
    echo -e "下载地址: ${YELLOW}http://${SERVER_IP}:8889/docker_full_backup.tar.gz${NC}"
    echo -e "备份完成后，建议在本机执行 ${GREEN}'2. 恢复原始 Nginx 配置'${NC} 选项以进行清理。"
}

### ========================================================= ###
###        ★ 安全的恢复流程 ★
### ========================================================= ###
full_docker_restore() {
    echo -e "\n${YELLOW}--- 开始通用 Docker 恢复 ---${NC}"
    ensure_packages "wget" "docker" "tar"
    read -p "请输入备份文件所在的服务器 IP 或域名: " BACKUP_IP
    if [ -z "$BACKUP_IP" ]; then echo -e "${RED}IP 地址不能为空。${NC}"; return 1; fi

    local DOWNLOAD_URL="http://${BACKUP_IP}:8889/docker_full_backup.tar.gz"
    local BACKUP_FILE="docker_full_backup.tar.gz"
    local RESTORE_DIR="migration_temp_$$"
    
    echo "1. 正在下载备份文件..."; wget -q --show-progress "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then echo -e "${RED}下载失败! 请检查 IP 地址和源服务器状态。${NC}"; return 1; fi
    echo -e "${GREEN}下载成功！${NC}"

    echo "2. 正在创建安全恢复目录: ${RESTORE_DIR}/"
    mkdir "$RESTORE_DIR"

    echo "3. 正在将备份文件安全解压到恢复目录..."
    # 这是关键的安全修改：不再解压到根目录 "/"
    tar -xzvf "$BACKUP_FILE" -C "${RESTORE_DIR}/"
    if [ $? -ne 0 ]; then echo -e "${RED}解压失败!${NC}"; rm -rf "$BACKUP_FILE" "$RESTORE_DIR"; return 1; fi
    
    # 找到恢复脚本
    local RESTORE_SCRIPT_PATH
    RESTORE_SCRIPT_PATH=$(find "${RESTORE_DIR}" -name "restore_all_containers.sh")

    if [ -z "$RESTORE_SCRIPT_PATH" ]; then
        echo -e "${RED}错误: 未在备份包中找到恢复脚本 'restore_all_containers.sh'。${NC}"
        rm -rf "$BACKUP_FILE" "$RESTORE_DIR"
        return 1
    fi
    echo -e "${GREEN}解压成功！恢复脚本位于: $RESTORE_SCRIPT_PATH${NC}"

    chmod +x "$RESTORE_SCRIPT_PATH"
    echo -e "\n${YELLOW}即将自动执行恢复脚本...${NC}"
    sleep 2

    # 执行恢复脚本
    "$RESTORE_SCRIPT_PATH"
    
    local SCRIPT_EXIT_CODE=$?
    if [ $SCRIPT_EXIT_CODE -ne 0 ]; then
        echo -e "\n${RED}恢复过程中发生错误，脚本已在失败的容器处终止。${NC}"
    else
        echo -e "\n${GREEN}--- ✅ 所有容器已成功恢复！ ---${NC}"
    fi

    # 清理工作
    echo -e "\n${YELLOW}清理临时文件...${NC}"
    rm "$BACKUP_FILE"
    echo "恢复后的数据卷保留在: ${RESTORE_DIR}/"
    echo "您可以确认所有服务正常后手动删除此目录: 'rm -rf ${RESTORE_DIR}'"

    # 自动显示最终状态
    echo -e "\n${YELLOW}--- 正在检查恢复后的容器状态... ---${NC}"
    docker ps
    echo -e "\n${GREEN}脚本执行完毕。${NC}"
}

# ==================================================
#                     程序主菜单
# ==================================================
main_menu() {
  while true; do
    echo -e "\n${Blue}======================================${Font}"
    echo -e "    Docker容器 迁移工具 "
    echo -e "${Blue}======================================${Font}"
    echo -e "  ${GREEN}1.${NC}  通用 Docker 容器迁移"
    echo -e "  ${GREEN}2.${NC}  清理临时的 Nginx 配置 "
    echo -e "  ${RED}3.${NC}  退出脚本"
    echo -e "${Blue}======================================${Font}"
    read -p "请输入选项 (1-3): " choice
    case $choice in
      1)
        while true; do
            echo -e "\n${Blue}--- 通用 Docker 迁移菜单 ---${Font}"
            echo " 1. 备份所有容器 (在源服务器执行)"
            echo " 2. 恢复所有容器 (在新服务器执行)"
            echo " 3. 返回主菜单"
            read -p "请选择 (1-3): " sub_choice
            case $sub_choice in
                1) full_docker_backup ;;
                2) 
                   full_docker_restore
                   echo "恢复流程结束。"
                   # 不再自动退出，允许用户查看状态
                   ;;
                3) break ;;
                *) echo -e "${RED}无效选项!${NC}" ;;
            esac
        done ;;
      2) restore_nginx_config ;;
      3) 
        # 在退出前执行一次最终清理
        trap - INT TERM # 移除自定义的信号捕获
        restore_nginx_config
        echo -e "${YELLOW}正在退出...${NC}"; exit 0 ;;
      *) echo -e "${RED}无效选项，请重试。${NC}" >&2 ;;
    esac
  done
}

# --- 脚本主入口 ---
check_root
main_menu

