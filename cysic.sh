#!/bin/bash
set -e

BASE_CONTAINER_NAME="cysic-node"
IMAGE_NAME="cysic-node:latest"
DATA_DIR="$HOME/cysic_data"
LOG_DIR="$HOME/cysic_logs"

# 检查 Docker 是否安装
function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "检测到未安装 Docker，正在安装..."
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update
        apt install -y docker-ce
        systemctl enable docker
        systemctl start docker
    fi
}

# 构建docker镜像函数
function build_image() {
    WORKDIR=$(mktemp -d)
    cd "$WORKDIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV REWARD_ADDRESS=""
ENV DATA_DIR="/cysic-data"

RUN apt-get update && apt-get install -y \\
    curl \\
    bash \\
    && rm -rf /var/lib/apt/lists/*

# 创建数据目录
RUN mkdir -p \$DATA_DIR

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e

if [ -z "\$REWARD_ADDRESS" ]; then
    echo "错误：未设置 REWARD_ADDRESS 环境变量"
    exit 1
fi

echo "使用的奖励地址: \$REWARD_ADDRESS"

# 检查是否已初始化
if [ ! -f "\$DATA_DIR/initialized" ]; then
    echo "首次运行，初始化节点..."
    curl -L https://github.com/cysic-labs/cysic-phase3/releases/download/v1.0.0/setup_linux.sh > \$DATA_DIR/setup_linux.sh
    chmod +x \$DATA_DIR/setup_linux.sh
    \$DATA_DIR/setup_linux.sh \$REWARD_ADDRESS
    touch \$DATA_DIR/initialized
    echo "节点初始化完成！"
fi

echo "启动验证器节点..."
cd \$DATA_DIR/cysic-verifier
bash start.sh

# 保持容器运行
tail -f /dev/null
EOF

    docker build --no-cache -t "$IMAGE_NAME" .

    cd -
    rm -rf "$WORKDIR"
}

# 启动容器
function run_container() {
    local reward_address=$1
    local container_name="${BASE_CONTAINER_NAME}-$(echo $reward_address | tail -c 7 | sed 's/^0x//')"
    local node_data_dir="${DATA_DIR}/${container_name}"
    local node_log_dir="${LOG_DIR}/${container_name}"

    # 创建数据目录
    mkdir -p "$node_data_dir"
    chmod 777 "$node_data_dir"
    
    # 创建日志目录
    mkdir -p "$node_log_dir"
    chmod 777 "$node_log_dir"

    if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
        echo "检测到旧容器 $container_name，先删除..."
        docker rm -f "$container_name"
    fi

    echo "启动容器 $container_name，奖励地址: $reward_address"
    docker run -d \
        --name "$container_name" \
        -v "$node_data_dir:/cysic-data" \
        -v "$node_log_dir:/var/log/cysic" \
        -e REWARD_ADDRESS="$reward_address" \
        "$IMAGE_NAME"
    
    echo "容器已启动！"
    echo "数据目录: $node_data_dir"
    echo "日志目录: $node_log_dir"
}

# 更新节点奖励地址
function update_reward_address() {
    local container_name=$1
    local new_address=$2
    local node_data_dir="${DATA_DIR}/${container_name}"

    if [ ! -d "$node_data_dir" ]; then
        echo "错误：找不到节点的数据目录"
        return 1
    fi

    echo "停止容器..."
    docker stop "$container_name"

    echo "更新奖励地址为: $new_address"
    echo "$new_address" > "$node_data_dir/reward_address"
    
    # 删除初始化标记以触发重新初始化
    rm -f "$node_data_dir/initialized"
    
    echo "重新启动容器..."
    docker start "$container_name"
    
    echo "奖励地址已更新！"
}

# 停止并卸载节点
function uninstall_node() {
    local container_name=$1

    echo "停止并删除容器 $container_name..."
    docker rm -f "$container_name" 2>/dev/null || echo "容器不存在或已停止"

    local node_data_dir="${DATA_DIR}/${container_name}"
    if [ -d "$node_data_dir" ]; then
        echo "删除数据目录 $node_data_dir ..."
        rm -rf "$node_data_dir"
    fi

    local node_log_dir="${LOG_DIR}/${container_name}"
    if [ -d "$node_log_dir" ]; then
        echo "删除日志目录 $node_log_dir ..."
        rm -rf "$node_log_dir"
    fi

    echo "节点 $container_name 已卸载完成。"
}

# 显示所有节点
function list_nodes() {
    echo "当前节点状态："
    echo "------------------------------------------------------------------------------------------------------------------------"
    printf "%-6s %-20s %-45s %-10s %-10s %-10s %-20s\n" "序号" "容器名称" "奖励地址" "CPU使用率" "内存使用" "内存限制" "状态"
    echo "------------------------------------------------------------------------------------------------------------------------"
    
    local all_containers=($(docker ps -a --filter "name=${BASE_CONTAINER_NAME}" --format "{{.Names}}"))
    for i in "${!all_containers[@]}"; do
        local container_name=${all_containers[$i]}
        local container_info=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}" $container_name 2>/dev/null)
        
        # 获取奖励地址
        local reward_address="N/A"
        local address_file="${DATA_DIR}/${container_name}/reward_address"
        if [ -f "$address_file" ]; then
            reward_address=$(cat "$address_file")
        fi
        
        if [ -n "$container_info" ]; then
            IFS=',' read -r cpu_usage mem_usage mem_limit <<< "$container_info"
            local status=$(docker inspect -f '{{.State.Status}}' "$container_name")
            
            printf "%-6d %-20s %-45s %-10s %-10s %-10s %-20s\n" \
                $((i+1)) \
                "$container_name" \
                "$reward_address" \
                "$cpu_usage" \
                "$(echo $mem_usage | awk '{print $1}')" \
                "$(echo $mem_limit | awk '{print $1}')" \
                "$status"
        else
            local status=$(docker inspect -f '{{.State.Status}}' "$container_name")
            printf "%-6d %-20s %-45s %-10s %-10s %-10s %-20s\n" \
                $((i+1)) \
                "$container_name" \
                "$reward_address" \
                "N/A" \
                "N/A" \
                "N/A" \
                "$status"
        fi
    done
    echo "------------------------------------------------------------------------------------------------------------------------"
}

# 查看节点日志
function view_node_logs() {
    local container_name=$1
    
    if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
        echo "查看 $container_name 日志，按 Ctrl+C 退出"
        docker logs -f "$container_name"
    else
        echo "容器未运行或不存在"
    fi
}

# 选择节点
function select_node() {
    local all_containers=($(docker ps -a --filter "name=${BASE_CONTAINER_NAME}" --format "{{.Names}}"))
    
    if [ ${#all_containers[@]} -eq 0 ]; then
        echo "当前没有节点"
        return 1
    fi

    echo "请选择节点："
    for i in "${!all_containers[@]}"; do
        echo "$((i+1)). ${all_containers[$i]}"
    done

    read -rp "请输入选项(1-${#all_containers[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#all_containers[@]} ]; then
        echo "${all_containers[$((choice-1))]}"
    else
        echo "无效选择"
        return 1
    fi
}

# 主菜单
while true; do
    clear
    echo "===== Cysic 节点管理脚本 ====="
    echo "1. 安装并启动新节点"
    echo "2. 显示所有节点状态"
    echo "3. 更新节点奖励地址"
    echo "4. 查看节点日志"
    echo "5. 停止并卸载节点"
    echo "6. 退出"
    echo "==============================="

    read -rp "请输入选项(1-6): " choice

    case $choice in
        1)
            check_docker
            read -rp "请输入您的奖励地址: " REWARD_ADDRESS
            if [ -z "$REWARD_ADDRESS" ]; then
                echo "奖励地址不能为空"
                read -p "按任意键继续"
                continue
            fi
            
            echo "开始构建镜像..."
            build_image
            
            echo "启动节点..."
            run_container "$REWARD_ADDRESS"
            
            read -p "节点已启动，按任意键返回菜单"
            ;;
        2)
            list_nodes
            read -p "按任意键返回菜单"
            ;;
        3)
            container=$(select_node)
            if [ -z "$container" ]; then
                read -p "按任意键返回菜单"
                continue
            fi
            
            read -rp "请输入新的奖励地址: " NEW_ADDRESS
            if [ -z "$NEW_ADDRESS" ]; then
                echo "奖励地址不能为空"
                read -p "按任意键继续"
                continue
            fi
            
            update_reward_address "$container" "$NEW_ADDRESS"
            read -p "地址已更新，按任意键返回菜单"
            ;;
        4)
            container=$(select_node)
            if [ -z "$container" ]; then
                read -p "按任意键返回菜单"
                continue
            fi
            
            view_node_logs "$container"
            read -p "按任意键返回菜单"
            ;;
        5)
            container=$(select_node)
            if [ -z "$container" ]; then
                read -p "按任意键返回菜单"
                continue
            fi
            
            read -rp "确定要卸载节点 $container 吗? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                uninstall_node "$container"
                read -p "节点已卸载，按任意键返回菜单"
            else
                echo "已取消操作"
                read -p "按任意键返回菜单"
            fi
            ;;
        6)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "无效选项"
            read -p "按任意键继续"
            ;;
    esac
done