#!/bin/bash
# AG Industrial Node Manager (Titan Fork)
# GitHub: https://github.com/your-repo

# Конфигурация
CONFIG_FILE="/etc/ag_nodes.conf"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/ag_logo"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BASE_IP="172.$(shuf -i 16-31 -n1).$(shuf -i 0-255 -n1).0"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
HW_TEMPLATES=("Xeon E5-2699v4" "EPYC 7R32" "Xeon Gold 6326")

declare -A USED_KEYS=()
declare -A USED_PORTS=()

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== AG INDUSTRIAL NODES ==="
    echo -e "\n1) Установить компоненты\n2) Создать ноды\n3) Проверить статус\n4) Показать логи\n5) Перезапустить\n6) Очистка\n7) Выход"
    echo -ne "${NC}"
}

generate_random_port() {
    while true; do
        port=$(shuf -i 30000-40000 -n1)
        [[ ! -v USED_PORTS[$port] ]] && ! ss -uln | grep -q ":${port} " && break
    done
    USED_PORTS[$port]=1
    echo "$port"
}

generate_realistic_profile() {
    echo "$((2 + RANDOM%4)),$((4 + RANDOM%8)),$((50 + RANDOM%50))"
}

generate_fake_mac() {
    printf "02:%02x:%02x:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

install_dependencies() {
    echo -e "${ORANGE}[*] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive

    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections"
    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections"

    sudo apt-get update -yq && sudo apt-get upgrade -yq
    sudo apt-get install -yq \
        apt-transport-https ca-certificates curl gnupg lsb-release \
        jq screen cgroup-tools net-tools ccze netcat iptables-persistent

    sudo ufw allow 1234/udp
    sudo ufw allow 30000:40000/udp
    sudo ufw reload

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    
    sudo apt-get update -yq && sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"

    echo -e "${GREEN}[✓] Система готова!${NC}"
    sleep 1
}

create_node() {
    local node_num=$1
    IFS=',' read -r cpu ram_gb ssd_gb <<< "$(generate_realistic_profile)"
    local port=$(generate_random_port)
    local volume="ag_data_$node_num"
    local node_ip="${BASE_IP%.*}.$(( ${BASE_IP##*.} + node_num ))"
    local mac=$(generate_fake_mac)

    # Ввод команд с сайта
    while true; do
        echo -e "${ORANGE}=== НОДА $node_num ===${NC}"
        read -p "Введите команду 1 (curl): " cmd1
        read -p "Введите команду 2 (chmod): " cmd2
        read -p "Введите команду 3 (запуск): " cmd3

        if [[ "$cmd1" =~ "curl -L" ]] && [[ "$cmd2" =~ "chmod +x" ]] && [[ "$cmd3" =~ "./launcher" ]]; then
            device_id=$(echo "$cmd3" | grep -oP "device_id=\K[^ ]+")
            [[ -z "${USED_KEYS[$device_id]}" ]] && break
            echo -e "${RED}Device ID уже используется!${NC}"
        else
            echo -e "${RED}Неверный формат команд! Пример:"
            echo "cmd1: curl -L .../launcher -o launcher && curl -L .../worker -o worker"
            echo "cmd3: ./launcher --user_did=... --device_id=... --device_name=..."
        fi
    done

    docker rm -f "ag_node_$node_num" 2>/dev/null
    docker volume create "$volume" >/dev/null || {
        echo -e "${RED}[✗] Ошибка создания тома $volume${NC}"
        return 1
    }

    # Запись конфига
    echo "$device_id" | docker run -i --rm -v "$volume:/data" busybox sh -c "cat > /data/identity.key" || {
        echo -e "${RED}[✗] Ошибка записи ключа${NC}"
        return 1
    }

    # Запуск контейнера
    if ! screen -dmS "node_$node_num" docker run -d \
        --name "ag_node_$node_num" \
        --restart unless-stopped \
        --cpus "$cpu" \
        --memory "${ram_gb}g" \
        --storage-opt "size=${ssd_gb}g" \
        --mac-address "$mac" \
        -p ${port}:${port}/udp \
        -v "$volume:/root/.ag" \
        ag-node:latest \
        --bind "0.0.0.0:${port}" \
        --storage-size "${ssd_gb}GB"; then
        echo -e "${RED}[✗] Ошибка запуска контейнера${NC}"
        return 1
    fi

    # Настройка сети
    sudo ip addr add "${node_ip}/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    sudo iptables -t nat -A PREROUTING -i $NETWORK_INTERFACE -p udp --dport $port -j DNAT --to-destination $node_ip:$port
    sudo netfilter-persistent save >/dev/null 2>&1

    echo -e "${ORANGE}[*] Инициализация ноды (2 мин)...${NC}"
    sleep 120

    printf "${GREEN}[✓] Нода %02d | IP: %s | Порт: %5d | Ресурсы: %d ядер, %dGB RAM, %dGB SSD | MAC: %s${NC}\n" \
        "$node_num" "$node_ip" "$port" "$cpu" "$ram_gb" "$ssd_gb" "$mac"
}

setup_nodes() {
    declare -A USED_KEYS=()
    
    while true; do
        read -p "Введите количество нод: " node_count
        [[ "$node_count" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}Ошибка: введите число > 0!${NC}"
    done

    for ((i=1; i<=node_count; i++)); do
        create_node "$i"
    done
}

check_nodes() {
    clear
    echo -e "${ORANGE}ТЕКУЩИЙ СТАТУС:${NC}"
    docker ps -a --filter "name=ag_node" --format '{{.Names}} {{.Status}} {{.Ports}}' | \
    awk '{
        status_color = ($2 ~ /Up/) ? "\033[32m" : "\033[31m";
        printf "%-15s %s%-12s\033[0m %s\n", $1, status_color, $2, $3
    }'

    echo -e "\n${ORANGE}СИНХРОНИЗАЦИЯ:${NC}"
    docker ps --filter "name=ag_node" --format "{{.Names}}" | xargs -I{} sh -c \
    'echo -n "{}: "; docker exec {} ag-cli info sync 2>/dev/null | grep "Progress" || echo "OFFLINE"'

    echo -e "\n${ORANGE}РЕСУРСЫ:${NC}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep "ag_node"

    read -p $'\nНажмите любую клавишу...' -n1 -s
    clear
}

show_logs() {
    read -p "Введите номер ноды: " num
    echo -e "${ORANGE}Логи ag_node_${num}:${NC}"
    logs=$(docker logs --tail 50 "ag_node_${num}" 2>&1 | grep -iE 'error|fail|warn|binding')
    if command -v ccze &>/dev/null; then
        echo "$logs" | ccze -A
    else
        echo "$logs"
    fi
    read -p $'\nНажмите любую клавишу...' -n1 -s
    clear
}

restart_nodes() {
    echo -e "${ORANGE}[*] Перезапуск нод...${NC}"
    docker ps -aq --filter "name=ag_node" | xargs -r docker rm -f
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        for key in "${!USED_KEYS[@]}"; do
            node_num=${key##*_}
            create_node "$node_num"
        done
        echo -e "${GREEN}[✓] Ноды перезапущены!${NC}"
    else
        echo -e "${RED}Конфигурация отсутствует!${NC}"
    fi
    sleep 2
}

cleanup() {
    echo -e "${RED}\n[!] ПОЛНАЯ ОЧИСТКА [!]${NC}"
    
    # Контейнеры
    echo -e "${ORANGE}[1/6] Удаление контейнеров...${NC}"
    docker ps -aq --filter "name=ag_node" | xargs -r docker rm -f

    # Тома
    echo -e "${ORANGE}[2/6] Удаление томов...${NC}"
    docker volume ls -q --filter "name=ag_data" | xargs -r docker volume rm

    # Сеть
    echo -e "${ORANGE}[3/6] Восстановление сети...${NC}"
    for i in {1..50}; do
        node_ip="${BASE_IP%.*}.$(( ${BASE_IP##*.} + i ))"
        sudo ip addr del "$node_ip/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    done
    sudo iptables -t nat -F && sudo iptables -t mangle -F
    sudo netfilter-persistent save >/dev/null 2>&1

    # Файлы
    echo -e "${ORANGE}[4/6] Удаление данных...${NC}"
    rm -rf /ag/*
    
    # Кэш
    echo -e "${ORANGE}[5/6] Очистка кэша...${NC}"
    sudo rm -rf /tmp/ag_* ~/.ag /var/cache/apt/archives/*.deb

    # Screen
    echo -e "${ORANGE}[6/6] Очистка сессий...${NC}"
    screen -ls | grep "node_" | awk -F. '{print $1}' | xargs -r -I{} screen -X -S {} quit

    echo -e "${GREEN}[✓] Все следы удалены! Перезагрузите сервер.${NC}"
    sleep 3
    clear
}

[ ! -f /etc/systemd/system/ag-node.service ] && sudo bash -c "cat > /etc/systemd/system/ag-node.service <<EOF
[Unit]
Description=AG Node Service
After=network.target docker.service

[Service]
ExecStart=$(realpath "$0") --auto-start
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF" && sudo systemctl enable ag-node.service >/dev/null 2>&1

case $1 in
    --auto-start)
        [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" && setup_nodes
        ;;
    *)
        while true; do
            show_menu
            read -p "Выбор: " choice
            case $choice in
                1) install_dependencies ;;
                2) setup_nodes ;;
                3) check_nodes ;;
                4) show_logs ;;
                5) restart_nodes ;;
                6) cleanup ;;
                7) exit 0 ;;
                *) echo -e "${RED}Неверный выбор!${NC}"; sleep 1 ;;
            esac
        done
        ;;
esac
