#!/bin/bash
# AG Industrial Node Manager (Titan-Style)
# GitHub: https://github.com/your-repo

# Конфигурация
CONFIG_FILE="/etc/ag_nodes.conf"
LOGO_URL="https://raw.githubusercontent.com/your-repo/main/ag_logo.txt"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BASE_IP="10.$((RANDOM%256)).$((RANDOM%256)).0"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}')

declare -A USED_IDS=()
declare -A USED_PORTS=()

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSLf "$LOGO_URL" 2>/dev/null || echo "=== AG INDUSTRIAL NODES ==="
    echo -e "\n1) Установить компоненты\n2) Создать ноды\n3) Проверить статус\n4) Показать логи\n5) Перезапустить\n6) Очистка\n7) Выход"
    echo -ne "${NC}"
}

generate_realistic_profile() {
    local cpu_values=(8 10 12 14 16 18 20 22 24 26 28 30 32)
    local cpu=${cpu_values[$RANDOM % ${#cpu_values[@]}]}
    local ram=$((32 + (RANDOM % 16) * 32))
    local ssd=$((512 + (RANDOM % 20) * 512))
    echo "$cpu,$ram,$ssd"
}

generate_fake_mac() {
    printf "02:%02X:%02X:%02X:%02X:%02X" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

validate_commands() {
    [[ "$1" =~ "curl -L https://github.com/.*launcher" ]] && 
    [[ "$2" =~ "chmod +x" ]] && 
    [[ "$3" =~ "./launcher --user_did=did:embarky:.*--device_id=.*--device_name=" ]]
}

deploy_node() {
    local node_num=$1
    IFS=',' read -r cpu ram ssd <<< "$(generate_realistic_profile)"
    local port=$(shuf -i 30000-40000 -n1)
    local node_ip="${BASE_IP%.*}.$(( ${BASE_IP##*.} + node_num ))"
    local mac=$(generate_fake_mac)
    local container_name="ag_node_$node_num"
    
    while true; do
        echo -e "${ORANGE}=== НОДА $node_num ===${NC}"
        read -p "1/3 Введите команду загрузки (curl): " cmd1
        read -p "2/3 Введите команду прав (chmod): " cmd2
        read -p "3/3 Введите команду запуска (./launcher): " cmd3

        if validate_commands "$cmd1" "$cmd2" "$cmd3"; then
            device_id=$(grep -oP "device_id=\K[^ ]+" <<< "$cmd3")
            [[ -z "${USED_IDS[$device_id]}" ]] && break
            echo -e "${RED}Ошибка: Device ID уже используется!${NC}"
        else
            echo -e "${RED}Неверный формат! Пример:"
            echo -e "CMD1: curl -L .../launcher -o launcher && curl -L .../worker -o worker"
            echo -e "CMD3: ./launcher --user_did=... --device_id=... --device_name=...${NC}"
        fi
    done

    {
        mkdir -p "/ag/$node_num" && cd "/ag/$node_num"
        eval "$cmd1" || { echo -e "${RED}Ошибка загрузки!${NC}"; return 1; }
        eval "$cmd2" || { echo -e "${RED}Ошибка прав доступа!${NC}"; return 1; }

        docker run -d \
            --name "$container_name" \
            --restart unless-stopped \
            --cpus "$cpu" \
            --memory "${ram}g" \
            --storage-opt "size=${ssd}g" \
            --mac-address "$mac" \
            -p "$port:$port" \
            -v "$PWD:/data" \
            alpine/node:18 \
            sh -c "$cmd3 --http_port=$port" || { echo -e "${RED}Ошибка запуска!${NC}"; return 1; }

        if docker logs "$container_name" 2>&1 | grep -qE "PIN: [0-9]{4}|ready for work"; then
            USED_IDS["$device_id"]=1
            echo "$node_num|$device_id|$mac|$port|$node_ip|$cpu|$ram|$ssd" >> "$CONFIG_FILE"
            echo -e "${GREEN}[✓] Нода $node_num | ${cpu} ядер | ${ram}GB RAM | ${ssd}GB SSD${NC}"
            echo -e "${ORANGE}PIN: $(docker logs $container_name | grep -oE 'PIN: [0-9]{4}')${NC}"
        else
            echo -e "${RED}[✗] Ошибка инициализации ноды $node_num!${NC}"
            docker rm -f "$container_name" >/dev/null
            return 1
        fi
    } 2>&1 | tee "/ag/$node_num/install.log"
}

setup_nodes() {
    declare -A USED_IDS=()
    
    while true; do
        read -p "Количество нод: " count
        [[ "$count" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}Ошибка: введите число > 0!${NC}"
    done

    for ((i=1; i<=count; i++)); do
        deploy_node $i
    done
}

check_status() {
    clear
    printf "${ORANGE}%-6s | %-4s | %-6s | %-6s | %-17s | %-15s | %s${NC}\n" "Нода" "CPU" "RAM" "SSD" "MAC" "IP" "Статус"
    
    while IFS='|' read -r num _ mac _ ip cpu ram ssd _; do
        if docker ps | grep -q "ag_node_$num"; then
            status="${GREEN}🟢${NC}"
        else
            status="${RED}🔴${NC}"
        fi
        printf "%-6s | %-4s | %-6s | %-6s | %-17s | %-15s | %b\n" \
            "#$num" "$cpu" "${ram}GB" "${ssd}GB" "$mac" "$ip" "$status"
    done < "$CONFIG_FILE"
    
    read -p $'\nНажмите Enter...' -n1 -s
}

show_logs() {
    read -p "Номер ноды: " num
    echo -e "${ORANGE}=== ЛОГИ НОДЫ #$num ===${NC}"
    docker logs --tail 50 "ag_node_$num" 2>&1 | ccze -A
    read -p $'\nНажмите Enter...' -n1 -s
}

cleanup() {
    echo -e "${RED}\n[!] ПОЛНАЯ ОЧИСТКА [!]${NC}"
    
    # Удаление контейнеров
    docker ps -aq --filter "name=ag_node_" | xargs -r docker rm -f
    
    # Очистка сети
    for i in {1..50}; do
        ip="${BASE_IP%.*}.$(( ${BASE_IP##*.} + i ))"
        sudo ip addr del "$ip/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    done
    sudo iptables -t nat -F
    
    # Удаление данных
    rm -rf /ag/*
    > "$CONFIG_FILE"
    
    echo -e "${GREEN}[✓] Все следы удалены!${NC}"
    sleep 2
}

install_dependencies() {
    echo -e "${ORANGE}[*] Установка компонентов...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    
    sudo apt-get update -yq && sudo apt-get upgrade -yq
    sudo apt-get install -yq \
        curl docker.io jq screen ccze \
        cgroup-tools iptables-persistent

    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
    
    echo -e "${GREEN}[✓] Зависимости установлены!${NC}"
    sleep 1
}

[ ! -f /etc/systemd/system/ag-node.service ] && sudo tee /etc/systemd/system/ag-node.service > /dev/null <<EOF
[Unit]
Description=AG Node Service
After=docker.service

[Service]
ExecStart=$(realpath "$0") --daemon
Restart=always

[Install]
WantedBy=multi-user.target
EOF

case $1 in
    --daemon)
        [ -f "$CONFIG_FILE" ] && while IFS='|' read -r num _ _ _ _ _ _ _; do
            deploy_node "$num"
        done < "$CONFIG_FILE"
        ;;
    *)
        while true; do
            show_menu
            read -p "${ORANGE}Выбор:${NC} " choice
            case $choice in
                1) install_dependencies ;;
                2) setup_nodes ;;
                3) check_status ;;
                4) show_logs ;;
                5) cleanup ;;
                6) exit 0 ;;
                *) echo -e "${RED}Неверный выбор!${NC}"; sleep 1 ;;
            esac
        done
        ;;
esac
