#!/bin/bash

# --- 定义颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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

# --- 智能修正 Nginx 配置结构的函数 ---
fix_nginx_symlink() {
  if [ -f "/etc/nginx/sites-enabled/default" ] && [ ! -L "/etc/nginx/sites-enabled/default" ]; then
    echo -e "${YELLOW}警告: 检测到非标准的 Nginx 配置，正在自动修正...${NC}"
    rm -f "/etc/nginx/sites-enabled/default"
    ln -s "/etc/nginx/sites-available/default" "/etc/nginx/sites-enabled/default"
    echo -e "${GREEN}Nginx 配置结构已修正为标准符号链接。${NC}"
    sleep 1
  fi
}

# --- ★ 通用功能: 启动 Nginx 临时下载服务器 ★ ---
setup_nginx_for_download() {
  if ss -tlpn | grep -q ':8889'; then
    echo -e "${GREEN}Nginx 临时下载服务器已在运行。${NC}"; return 0
  fi
  echo -e "${YELLOW}正在配置 Nginx 临时文件服务器...${NC}"
  fix_nginx_symlink
  local NGINX_CONF="/etc/nginx/sites-available/default"
  local NGINX_BAK_FILE="$NGINX_CONF.bak_script"
  if [ ! -f "$NGINX_BAK_FILE" ]; then
      cp "$NGINX_CONF" "$NGINX_BAK_FILE"
      echo "已创建原始 Nginx 配置文件备份: ${GREEN}$NGINX_BAK_FILE${NC}"
  fi
read -r -d '' NGX_DL_CONF <<'EOF'
server { listen 8889 default_server; root /var/www/html; server_name _; access_log off; autoindex on; location / { try_files $uri =404; } }
EOF
  echo "$NGX_DL_CONF" > "$NGINX_CONF"
  mkdir -p /var/www/html
  nginx -t && systemctl restart nginx
  if [ $? -ne 0 ]; then
    echo -e "${RED}启动 Nginx 临时服务器失败！正在恢复...${NC}"; cp "$NGINX_BAK_FILE" "$NGINX_CONF"; nginx -t && systemctl restart nginx
    return 1
  fi
  echo -e "${GREEN}Nginx 已成功配置在 8889 端口用于文件下载。${NC}"; return 0
}

# --- ★ 通用功能: 恢复原始 Nginx 配置 ★ ---
restore_nginx_config() {
    local NGINX_CONF="/etc/nginx/sites-available/default"
    local NGINX_BAK_FILE="$NGINX_CONF.bak_script"
    if [ -f "$NGINX_BAK_FILE" ]; then
        echo -e "${YELLOW}检测到配置文件备份，正在恢复 Nginx 原始配置...${NC}"
        cp "$NGINX_BAK_FILE" "$NGINX_CONF"
        rm "$NGINX_BAK_FILE"
        nginx -t && systemctl restart nginx
        if [ $? -ne 0 ]; then
            echo -e "${RED}恢复 Nginx 配置失败，请手动检查。${NC}"
        else
            echo -e "${GREEN}Nginx 原始配置已成功恢复。${NC}"
        fi
    else
        echo -e "${YELLOW}未找到由本脚本创建的 Nginx 备份文件，无需恢复。${NC}"
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
    local RESTORE_SCRIPT="restore_all_containers.sh"
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
    } > "${BACKUP_DIR}/${RESTORE_SCRIPT}"

    for container in $CONTAINERS; do
        echo -e "\n${YELLOW}--- 正在处理容器: $container ---${NC}"
        echo "1. 生成 'docker run' 命令..."
        local RUN_COMMAND
        RUN_COMMAND=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock assaflavie/runlike "$container")
        local CLEANED_COMMAND
        CLEANED_COMMAND=$(echo "$RUN_COMMAND" | sed -E 's/--hostname=[^ ]+ //g; s/--mac-address=[^ ]+ //g')

        {
            echo ""
            echo "echo -e \"\n\${GREEN}--- 正在恢复容器: $container ---\${NC}\""
            echo "CID=\$($CLEANED_COMMAND)"
            echo "if [ -n \"\$CID\" ]; then"
            echo "echo -e \"\${GREEN}容器 $container 恢复成功！ (ID: \$(echo \$CID | cut -c1-12)) \${NC}\""
            echo "else"
            echo "echo -e \"\${RED}容器 $container 恢复失败，请检查 Docker 日志！\${NC}\"; exit 1"
            echo "fi"
        } >> "${BACKUP_DIR}/${RESTORE_SCRIPT}"

        echo "2. 提取挂载卷路径..."
        docker inspect "$container" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' >> "${BACKUP_DIR}/${VOLUME_PATHS_FILE}.tmp"
    done

    sort -u "${BACKUP_DIR}/${VOLUME_PATHS_FILE}.tmp" > "${BACKUP_DIR}/${VOLUME_PATHS_FILE}"
    rm "${BACKUP_DIR}/${VOLUME_PATHS_FILE}.tmp"

    echo -e "\n${YELLOW}--- 开始打包 ---${NC}"
    tar -czvf docker_full_backup.tar.gz --absolute-names -C "${BACKUP_DIR}" "${RESTORE_SCRIPT}" -C / -T "${BACKUP_DIR}/${VOLUME_PATHS_FILE}"
    if [ $? -ne 0 ]; then echo -e "${RED}打包失败!${NC}"; rm -rf "$BACKUP_DIR"; return 1; fi
    rm -rf "$BACKUP_DIR"
    echo -e "${GREEN}打包成功！${NC}"

    echo "配置下载服务器..."
    setup_nginx_for_download
    if [ $? -ne 0 ]; then echo -e "${RED}无法配置下载服务器，中止备份。${NC}"; return 1; fi
    mv docker_full_backup.tar.gz /var/www/html/docker_full_backup.tar.gz

    local SERVER_IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}--- ✅  Docker容器 备份完成！ ---${NC}"
    echo -e "下载地址: ${YELLOW}http://${SERVER_IP}:8889/docker_full_backup.tar.gz${NC}"
}

full_docker_restore() {
    echo -e "\n${YELLOW}--- 开始通用 Docker 恢复 ---${NC}"
    ensure_packages "wget" "docker" "tar"
    read -p "请输入备份文件所在的服务器 IP 或域名: " BACKUP_IP
    if [ -z "$BACKUP_IP" ]; then echo -e "${RED}IP 地址不能为空。${NC}"; return 1; fi

    local DOWNLOAD_URL="http://${BACKUP_IP}:8889/docker_full_backup.tar.gz"
    local BACKUP_FILE="docker_full_backup.tar.gz"
    local RESTORE_SCRIPT="restore_all_containers.sh"

    echo "1. 正在下载备份文件..."; wget -q --show-progress "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then echo -e "${RED}下载失败! 请检查 IP 地址和源服务器状态。${NC}"; return 1; fi
    echo -e "${GREEN}下载成功！${NC}"

    echo "2. 正在解压备份文件..."
    tar -xzvf "$BACKUP_FILE" -C / >/dev/null 2>&1
    if [ $? -ne 0 ]; then echo -e "${RED}解压失败!${NC}"; rm "$BACKUP_FILE"; return 1; fi

    if [ -f "/${RESTORE_SCRIPT}" ]; then mv "/${RESTORE_SCRIPT}" "./${RESTORE_SCRIPT}"; fi
    if [ ! -f "$RESTORE_SCRIPT" ]; then echo -e "${RED}错误: 未在备份包中找到恢复脚本 '${RESTORE_SCRIPT}'。${NC}"; rm "$BACKUP_FILE"; return 1; fi
    echo -e "${GREEN}解压成功！${NC}"

    chmod +x "$RESTORE_SCRIPT"
    echo -e "\n${YELLOW}即将自动执行恢复脚本...${NC}"
    sleep 2

    # 执行恢复脚本
    ./"$RESTORE_SCRIPT"
    
    local SCRIPT_EXIT_CODE=$?
    if [ $SCRIPT_EXIT_CODE -ne 0 ]; then
        echo -e "\n${RED}恢复过程中发生错误，脚本已在失败的容器处终止。${NC}"
    else
        echo -e "\n${GREEN}--- ✅ 所有容器已成功恢复！ ---${NC}"
    fi

    # 清理工作
    rm "$BACKUP_FILE" "$RESTORE_SCRIPT"

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
    echo -e "\n============================================="
    echo -e "  Docker容器 迁移工具 (by:ceocok)"
    echo -e "============================================="
    echo -e "  ${YELLOW}1.${NC} ★★★ 通用 Docker容器 迁移 ★★★"
    echo "---------------------------------------------"
    echo -e "  ${GREEN}2.${NC} [在源服务器] 恢复原始 Nginx 配置"
    echo -e "  ${RED}3.${NC} 退出脚本"
    echo "============================================="
    read -p "请输入选项 (1-3): " choice
    case $choice in
      1)
        while true; do
            echo -e "\n--- 通用 Docker 迁移菜单 ---"
            echo " 1. 备份所有容器 (在源服务器执行)"
            echo " 2. 恢复所有容器 (在新服务器执行)"
            echo " 3. 返回主菜单"
            read -p "请选择 (1-3): " sub_choice
            case $sub_choice in
                1) full_docker_backup ;;
                2) 
                   full_docker_restore
                   # 恢复后直接退出脚本
                   exit 0
                   ;;
                3) break ;;
                *) echo -e "${RED}无效选项!${NC}" ;;
            esac
        done ;;
      2) restore_nginx_config ;;
      3) echo -e "${YELLOW}正在退出...${NC}"; exit 0 ;;
      *) echo -e "${RED}无效选项，请重试。${NC}" >&2 ;;
    esac
  done
}

# --- 脚本主入口 ---
check_root
main_menu
