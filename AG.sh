#!/bin/bash

# Конфигурация
CONFIG_FILE="/etc/ag_nodes.conf"
LOGO_URL="https://raw.githubusercontent.com/AG-Abuse/Assets/main/logo"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BASE_IP="10.$(shuf -i 0-255 -n1).$(shuf -i 0-255 -n1).0"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}')
declare -A USED_IDS=()
declare -A USED_PORTS=()

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== AG INDUSTRIAL NODES v3 ==="
    echo -e "\n1) Создать ноды\n2) Статус\n3) Логи\n4) Перезапуск\n5) Удалить всё\n6) Выход"
    echo -ne "${NC}"
}

generate_mac() {
    printf "02:%02x:%02x:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

validate_commands() {
    [[ "$1" =~ "curl -L https://github.com.*launcher" ]] &&
    [[ "$2" =~ "chmod +x" ]] &&
    [[ "$3" =~ "./launcher --user_did=did:embarky:.*--device_id=.*--device_name=" ]]
}

deploy_node() {
    local node_num=$1
    local node_name=""
    local node_ip="${BASE_IP%.*}.$((${BASE_IP##*.} + node_num))"
    
    while true; do
        echo -e "\n${ORANGE}=== НОДА $node_num ==="
        read -p "CMD1 (curl): " cmd1
        read -p "CMD2 (chmod): " cmd2
        read -p "CMD3 (launch): " cmd3
        
        if validate_commands "$cmd1" "$cmd2" "$cmd3"; then
            node_name=$(echo "$cmd3" | grep -oP -- "--device_name=\K[^-]+")
            [[ -z "${USED_IDS[$node_name]}" ]] && break
            echo -e "${RED}Имя уже используется!${NC}"
        else
            echo -e "${RED}Неверный формат команд! Пример:${NC}"
            echo "CMD1: curl -L .../launcher -o launcher"
            echo "CMD3: ./launcher --user_did=... --device_id=... --device_name=..."
        fi
    done

    # Генерация уникальных параметров
    local mac=$(generate_mac)
    local port=$((30000 + RANDOM%10000))
    
    # Настройка сети
    sudo ip link add dev ag-$node_num type dummy 2>/dev/null
    sudo ip addr add $node_ip/24 dev $NETWORK_INTERFACE
    sudo iptables -t nat -A PREROUTING -i $NETWORK_INTERFACE -p tcp --dport $port -j DNAT --to-destination $node_ip:$port

    # Запуск в Docker
    {
        mkdir -p /ag/$node_name && cd /ag/$node_name
        eval "$cmd1 && $cmd2"
        
        docker run -d \
            --name "ag_$node_name" \
            --restart unless-stopped \
            --mac-address $mac \
            --cpus 0.5 \
            --memory 1G \
            -p $port:$port \
            -v /ag/$node_name:/data \
            alpine/node:18 \
            sh -c "$cmd3 --http_port=$port"
            
        USED_IDS["$node_name"]="$mac|$port|$node_ip"
        echo "$node_name|$mac|$port|$node_ip|$(date +%s)" >> $CONFIG_FILE
    } 2>&1 | tee /ag/$node_name/install.log

    echo -e "${GREEN}Нода $node_name запущена!${NC}"
    sleep 1
}

setup_nodes() {
    read -p "Количество нод: " count
    [[ ! "$count" =~ ^[1-9][0-9]*$ ]] && echo -e "${RED}Ошибка!${NC}" && return
    
    for ((i=1; i<=count; i++)); do
        deploy_node $i
    done
}

check_status() {
    clear
    printf "${ORANGE}%-20s | %-17s | %-15s | %-15s | %s${NC}\n" "Имя" "MAC" "Порт" "IP" "Статус"
    
    while IFS='|' read -r name mac port ip timestamp; do
        if docker ps | grep -q "ag_$name"; then
            status="${GREEN}🟢 ALIVE${NC}"
        else
            status="${RED}🔴 DEAD${NC}"
        fi
        
        printf "%-20s | %-17s | %-15s | %-15s | %b\n" "$name" "$mac" "$port" "$ip" "$status"
    done < $CONFIG_FILE
    
    echo -e "\n${ORANGE}РЕСУРСЫ:${NC}"
    docker stats --no-stream --format "{{.Name}}: {{.CPUPerc}} CPU / {{.MemUsage}}" | grep "ag_"
    
    read -p $'\nНажмите Enter...'
}

show_logs() {
    read -p "Имя ноды: " name
    echo -e "${ORANGE}Логи $name:${NC}"
    docker logs --tail 50 "ag_$name" 2>&1 | grep -iE 'error|warn|fail' | ccze -A
    read -p $'\nНажмите Enter...'
}

restart_nodes() {
    echo -e "${ORANGE}[*] Перезапуск нод...${NC}"
    while IFS='|' read -r name _ _ _ _; do
        docker restart "ag_$name" >/dev/null
    done < $CONFIG_FILE
    echo -e "${GREEN}[✓] Ноды перезапущены!${NC}"
    sleep 1
}

nuke_system() {
    echo -e "${RED}\n[!] УНИЧТОЖЕНИЕ [!]${NC}"
    
    # Удаление Docker-ресурсов
    docker ps -aq --filter "name=ag_" | xargs -r docker rm -f
    docker network prune -f
    
    # Очистка сети
    for i in {1..50}; do
        sudo ip link del dev ag-$i 2>/dev/null
        sudo ip addr del "${BASE_IP%.*}.$(( ${BASE_IP##*.} + i ))/24" dev $NETWORK_INTERFACE 2>/dev/null
    done
    sudo iptables -t nat -F
    
    # Удаление данных
    rm -rf /ag/*
    > $CONFIG_FILE
    
    echo -e "${GREEN}[✓] Система очищена!${NC}"
    sleep 1
}

# Основной цикл
while true; do
    show_menu
    read -p "Выбор: " choice
    case $choice in
        1) setup_nodes ;;
        2) check_status ;;
        3) show_logs ;;
        4) restart_nodes ;;
        5) nuke_system ;;
        6) exit 0 ;;
        *) echo -e "${RED}Ошибка выбора!${NC}"; sleep 1 ;;
    esac
done
