#!/bin/bash

# --- 定义颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 全局变量和系统检测 ---
OS_TYPE=""
NGINX_CONF_DIR=""
NGINX_WEB_ROOT=""

# --- 基础工具函数 ---

detect_os() {
	case "$(uname -s)" in
		Linux*)  OS_TYPE="linux"; NGINX_CONF_DIR="/etc/nginx"; NGINX_WEB_ROOT="/var/www/html";;
		Darwin*) OS_TYPE="macos";
				 if [ -d "/opt/homebrew" ]; then
					 NGINX_CONF_DIR="/opt/homebrew/etc/nginx"; NGINX_WEB_ROOT="/opt/homebrew/var/www";
				 else
					 NGINX_CONF_DIR="/usr/local/etc/nginx"; NGINX_WEB_ROOT="/usr/local/var/www";
				 fi
				 ;;
		*)       echo -e "${RED}错误: 不支持的操作系统: $(uname -s)${NC}" >&2; exit 1;;
	esac
	echo -e "${GREEN}检测到操作系统: $OS_TYPE${NC}"
}

check_privileges() {
	# 在Linux上, 脚本必须以root权限运行以避免各种文件权限问题
	if [[ "$OS_TYPE" == "linux" && "$(id -u)" -ne 0 ]]; then
		echo -e "${RED}错误: 在 Linux 上, 此脚本必须以 root 权限运行。${NC}" >&2
		echo -e "${YELLOW}请尝试使用: sudo $0${NC}"
		exit 1
	fi
}

ensure_packages() {
	local pkgs_to_install=()
	for pkg in "$@"; do
		if ! command -v "$pkg" &> /dev/null; then
			[[ "$OS_TYPE" == "macos" && "$pkg" == "docker" ]] && { echo -e "${RED}错误: Docker Desktop for Mac 未安装。请先从官网安装。${NC}" >&2; return 1; }
			pkgs_to_install+=("$pkg")
		fi
	done

	if [ ${#pkgs_to_install[@]} -eq 0 ]; then return 0; fi

	echo -e "${YELLOW}以下依赖需要安装: ${pkgs_to_install[*]}${NC}"
	read -p "是否继续安装? (Y/N): " confirm_install
	[[ ! "$confirm_install" =~ ^[Yy]$ ]] && { echo "安装取消。"; return 1; }

	if [[ "$OS_TYPE" == "linux" ]]; then
		PKG_MANAGER=""
		if grep -qE 'ubuntu|debian' /etc/os-release; then
			PKG_MANAGER="apt-get"
			echo "正在更新包列表..."; sudo $PKG_MANAGER update -y >/dev/null
		elif grep -qE 'centos|rhel|fedora' /etc/os-release; then
			PKG_MANAGER="yum"
			command -v dnf &>/dev/null && PKG_MANAGER="dnf"
		else
			echo -e "${RED}错误: 不支持的 Linux 发行版。${NC}"; return 1
		fi
		sudo $PKG_MANAGER install -y "${pkgs_to_install[@]}" || { echo -e "${RED}依赖安装失败。${NC}"; return 1; }
	elif [[ "$OS_TYPE" == "macos" ]]; then
		command -v brew &> /dev/null || { echo -e "${RED}错误: Homebrew 未安装 (brew.sh)。${NC}"; return 1; }
		brew install "${pkgs_to_install[@]}" || { echo -e "${RED}依赖安装失败。${NC}"; return 1; }
	fi
}

# --- Nginx Web服务器 相关函数 ---

NGINX_TEMP_CONF_NAME="docker_migration_server.conf"

get_server_ip() {
	local ip_addr
	ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -n 1)
	if [ -z "$ip_addr" ]; then
		ip_addr=$(curl -s --connect-timeout 2 https://api.ipify.org) || ip_addr="[无法获取公网IP]"
	fi
	echo "$ip_addr"
}

setup_nginx_for_download() {
	local conf_path conf_link_path
	if [[ "$OS_TYPE" == "linux" ]]; then
		conf_path="${NGINX_CONF_DIR}/sites-available/${NGINX_TEMP_CONF_NAME}"
		conf_link_path="${NGINX_CONF_DIR}/sites-enabled/${NGINX_TEMP_CONF_NAME}"
	else
		mkdir -p "${NGINX_CONF_DIR}/servers"
		conf_path="${NGINX_CONF_DIR}/servers/${NGINX_TEMP_CONF_NAME}"
	fi

	if [ -f "$conf_path" ]; then
		echo -e "${GREEN}Nginx 临时下载服务器已配置。${NC}"; return 0
	fi
	
	echo -e "${YELLOW}正在配置 Nginx 提供下载服务...${NC}"
	sudo mkdir -p "$NGINX_WEB_ROOT"
	local nginx_config="server { listen 8889; server_name _; root ${NGINX_WEB_ROOT}; autoindex on; access_log off; }"
	echo "$nginx_config" | sudo tee "$conf_path" > /dev/null
	
	[[ "$OS_TYPE" == "linux" ]] && sudo ln -sf "$conf_path" "$conf_link_path"

	echo "正在测试并重载 Nginx..."
	if ! sudo nginx -t; then
		echo -e "${RED}Nginx 配置测试失败！请手动检查。${NC}"
		sudo rm -f "$conf_path" "$conf_link_path" &>/dev/null
		return 1
	fi

	if [[ "$OS_TYPE" == "linux" ]]; then sudo systemctl reload nginx; else brew services reload nginx &>/dev/null || brew services restart nginx &>/dev/null; fi
	if [ $? -ne 0 ]; then
		echo -e "${RED}重载 Nginx 失败。请检查端口 8889 是否被占用。${NC}"
		sudo rm -f "$conf_path" "$conf_link_path" &>/dev/null
		return 1
	fi
	echo -e "${GREEN}Nginx 临时下载服务器已在端口 8889 启动。${NC}"
}

restore_nginx_config() {
	local conf_path conf_link_path
	if [[ "$OS_TYPE" == "linux" ]]; then
		conf_path="${NGINX_CONF_DIR}/sites-available/${NGINX_TEMP_CONF_NAME}"
		conf_link_path="${NGINX_CONF_DIR}/sites-enabled/${NGINX_TEMP_CONF_NAME}"
	else
		conf_path="${NGINX_CONF_DIR}/servers/${NGINX_TEMP_CONF_NAME}"
	fi

	if [ ! -f "$conf_path" ]; then
		echo -e "${YELLOW}未找到 Nginx 临时配置，无需清理。${NC}"; return
	fi
	
	echo -e "${YELLOW}正在移除 Nginx 临时配置...${NC}"
	sudo rm -f "$conf_path" "$conf_link_path" &>/dev/null

	if sudo nginx -t &>/dev/null; then
		if [[ "$OS_TYPE" == "linux" ]]; then sudo systemctl reload nginx; else brew services reload nginx &>/dev/null || brew services restart nginx &>/dev/null; fi
	else
		echo -e "${RED}警告: 移除临时配置后 Nginx 配置异常。请手动检查!${NC}"
	fi
	echo -e "${GREEN}Nginx 临时配置已清理。${NC}"
}

# --- Docker 核心功能函数 ---

check_runlike() {
	if ! docker image inspect assaflavie/runlike:latest &>/dev/null; then
		echo -e "${YELLOW}迁移工具 'runlike' 未安装，正在拉取镜像...${NC}"
		docker pull assaflavie/runlike:latest || { echo -e "${RED}拉取 'runlike' 镜像失败。请检查网络和 Docker 环境。${NC}"; return 1; }
	fi
	return 0
}

### ========================================================= ###
###           ★ 功能1: Docker 迁移备份 ★
### ========================================================= ###
migration_backup() {
	echo -e "\n${BLUE}--- 1. Docker 迁移备份 (源服务器) ---${NC}"
	ensure_packages "docker" "tar" "gzip" "nginx" "curl" || return 1
	check_runlike || return 1

	local ALL_CONTAINERS; ALL_CONTAINERS=$(docker ps --format '{{.Names}}')
	[ -z "$ALL_CONTAINERS" ] && { echo -e "${RED}错误: 未找到任何正在运行的容器。${NC}"; return 1; }

	echo "当前正在运行的容器:"; echo -e "${GREEN}${ALL_CONTAINERS}${NC}"
	read -p "请输入要备份的容器名称 (用空格分隔, 回车备份所有): " -r user_input
	
	local TARGET_CONTAINERS=()
	if [ -z "$user_input" ]; then
		TARGET_CONTAINERS=($ALL_CONTAINERS)
	else
		read -ra TARGET_CONTAINERS <<< "$user_input"
	fi

	local DATA_ARCHIVE_NAME="docker_data.tar.gz"
	local START_SCRIPT_NAME="docker_run.sh"
	local TEMP_DIR; TEMP_DIR=$(mktemp -d)

	echo "#!/bin/bash" > "${TEMP_DIR}/${START_SCRIPT_NAME}"
	echo "set -e" >> "${TEMP_DIR}/${START_SCRIPT_NAME}"
	echo "# Auto-generated by Docker Migration Tool. Run this script after restoring data." >> "${TEMP_DIR}/${START_SCRIPT_NAME}"

	local volume_paths_file="${TEMP_DIR}/volume_paths.txt"
	
	for c in "${TARGET_CONTAINERS[@]}"; do
		if ! docker ps -q --filter "name=^/${c}$" | grep -q .; then
			echo -e "${RED}错误: 容器 '$c' 不存在或未运行，已跳过。${NC}"; continue
		fi
		echo -e "\n${YELLOW}正在备份容器文件并生成安装命令: $c ...${NC}"
		
		# 1. 记录数据卷的绝对路径
		docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' >> "${volume_paths_file}"
		
		# 2. 生成原始的、干净的 docker run 命令
		local run_cmd; run_cmd=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock assaflavie/runlike "$c")
		local clean_cmd; clean_cmd=$(echo "$run_cmd" | sed -E 's/--hostname=[^ ]+ //g; s/--mac-address=[^ ]+ //g')
		
		echo "" >> "${TEMP_DIR}/${START_SCRIPT_NAME}"
		echo "echo -e \"\n${GREEN}>>> 正在启动容器: $c${NC}\"" >> "${TEMP_DIR}/${START_SCRIPT_NAME}"
		echo "$clean_cmd" >> "${TEMP_DIR}/${START_SCRIPT_NAME}"
	done
	
	# 去重并检查是否有数据卷
	sort -u "${volume_paths_file}" -o "${volume_paths_file}"
	if [ ! -s "${volume_paths_file}" ]; then
		echo -e "${YELLOW}警告: 所选容器没有发现任何挂载的数据卷。只生成启动脚本。${NC}"
		sudo touch "${TEMP_DIR}/${DATA_ARCHIVE_NAME}" # 创建空包
	else
		echo -e "\n${YELLOW}正在打包所有数据卷...${NC}"
		# 使用 -P (或 --absolute-names) 来保留绝对路径，-C / 从根目录开始打包
		if ! sudo tar -czpf "${TEMP_DIR}/${DATA_ARCHIVE_NAME}" -P -C / -T "${volume_paths_file}"; then
			 echo -e "${RED}打包数据卷失败!${NC}"; sudo rm -rf "$TEMP_DIR"; return 1;
		fi
	fi

	setup_nginx_for_download || { sudo rm -rf "$TEMP_DIR"; return 1; }
	sudo mv "${TEMP_DIR}"/* "${NGINX_WEB_ROOT}/"
	sudo rm -rf "$TEMP_DIR"
	
	local server_ip; server_ip=$(get_server_ip)
	echo -e "\n${GREEN}--- ✅  备份完成！【请在新服务器恢复完后再退出脚本】！！ ---${NC}"
	echo -e "在新服务器上，输入源服务器的IP或域名将会自动下载以下备份文件:"
	echo -e "1. 数据包:   ${BLUE}http://${server_ip}:8889/${DATA_ARCHIVE_NAME}${NC}"
	echo -e "2. 启动脚本: ${BLUE}http://${server_ip}:8889/${START_SCRIPT_NAME}${NC}"
}

### ========================================================= ###
###           ★ 功能2: Docker 备份恢复 ★
### ========================================================= ###
migration_restore() {
	echo -e "\n${BLUE}--- 2. Docker 备份恢复 (新服务器) ---${NC}"
	ensure_packages "wget" "tar" "gzip" "docker" || return 1
	
	local DATA_ARCHIVE_NAME="docker_data.tar.gz"
	local START_SCRIPT_NAME="docker_run.sh"

	read -p "请输入源服务器的 IP 地址或域名: " source_ip
	[ -z "$source_ip" ] && { echo -e "${RED}IP 地址不能为空。${NC}"; return 1; }

	local data_url="http://${source_ip}:8889/${DATA_ARCHIVE_NAME}"
	local script_url="http://${source_ip}:8889/${START_SCRIPT_NAME}"

	echo "正在下载启动脚本..."
	wget -q --show-progress "$script_url" -O "$START_SCRIPT_NAME" || { echo -e "${RED}下载启动脚本失败!${NC}"; return 1; }
	echo "正在下载备份数据包..."
	wget -q --show-progress "$data_url" -O "$DATA_ARCHIVE_NAME" || { echo -e "${RED}下载备份数据包失败!${NC}"; rm -f "$START_SCRIPT_NAME"; return 1; }
	
	echo -e "\n${YELLOW}正在解压数据到容器指定路径...${NC}"
	# 使用 -P 来处理绝对路径, -p 保留权限, -C / 在根目录解压
	if ! sudo tar -xzpf "$DATA_ARCHIVE_NAME" -P -C /; then
		echo -e "${RED}解压数据失败！请检查文件是否损坏或磁盘空间。${NC}"
		return 1
	fi
	sudo chmod +x "$START_SCRIPT_NAME"

	echo -e "\n${GREEN}--- 数据已恢复完毕，准备启动容器... ---${NC}"
	echo "正在执行启动脚本..."
	if sudo ./"$START_SCRIPT_NAME"; then
		echo -e "\n${GREEN}--- ✅ 容器启动脚本执行完毕！---${NC}"
		
		echo "正在自动清理临时文件..."
		sudo rm -f "$DATA_ARCHIVE_NAME" "$START_SCRIPT_NAME"
		echo "临时文件已清理。"
		docker ps -a
	else
		echo -e "\n${RED}容器启动脚本执行时发生错误！请检查上面的日志输出。${NC}"
	fi
}

# ==================================================
#                     程序主菜单
# ==================================================
main_menu() {
	while true; do
		echo -e "\n${BLUE}=============================================${NC}"
		echo -e "      Docker 迁移与备份工具 v4.1 (by:ceocok)"
		echo -e "${BLUE}=============================================${NC}"
		echo -e "  --- 请选择操作 ---"
		echo -e "  ${GREEN}1.${NC}  Docker 迁移备份 (在源服务器运行)"
		echo -e "  ${GREEN}2.${NC}  Docker 备份恢复 (在新服务器运行)"
		echo ""
		echo -e "  ${RED}3.${NC}  退出"
		echo -e "${BLUE}=============================================${NC}"
		read -p "请输入选项 (1-3): " choice

		case $choice in
			1) migration_backup ;;
			2) migration_restore ;;
			3) trap - INT TERM; restore_nginx_config &>/dev/null; echo -e "\n${GREEN}脚本执行完毕，感谢使用！NodeSeek见！${NC}"; exit 0 ;;
			*) echo -e "${RED}无效选项。${NC}" ;;
		esac
	done
}

# --- 脚本主入口 ---
trap "echo -e '\n捕获到退出信号，正在清理...'; restore_nginx_config &>/dev/null; exit 1" INT TERM
clear
detect_os
check_privileges
main_menu
