#!/bin/bash
# AG Node Manager (Titan-Style)
# GitHub: https://github.com/your-repo

# Конфигурация
CONFIG_FILE="/etc/ag_nodes.conf"
LOGO_URL="https://raw.githubusercontent.com/your-repo/main/logo.txt"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}')

declare -A USED_IDS=()

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== AG INDUSTRIAL NODES ==="
    echo -e "${NC}\n1) Установить ноды\n2) Статус нод\n3) Логи\n4) Перезапуск\n5) Очистка\n6) Выход\n"
}

validate_commands() {
    [[ "$1" =~ "curl -L https://github.com.*launcher" ]] && 
    [[ "$2" =~ "chmod +x" ]] && 
    [[ "$3" =~ "./launcher --user_did=did:embarky:.*--device_id=.*--device_name=" ]]
}

deploy_node() {
    local idx=$1
    echo -e "${ORANGE}=== НОДА $idx ===${NC}"
    
    # Ввод команд
    read -p "Введите команду 1 (curl): " cmd1
    read -p "Введите команду 2 (chmod): " cmd2
    read -p "Введите команду 3 (./launcher): " cmd3
    
    # Проверка формата
    if ! validate_commands "$cmd1" "$cmd2" "$cmd3"; then
        echo -e "${RED}Ошибка: Неверный формат команд!${NC}"
        return 1
    fi
    
    # Извлечение параметров
    local device_id=$(grep -oP "device_id=\K[^ ]+" <<< "$cmd3")
    local node_name=$(grep -oP "device_name=\K[^ ]+" <<< "$cmd3")
    
    # Проверка дубликатов
    if [[ -n "${USED_IDS[$device_id]}" ]]; then
        echo -e "${RED}Ошибка: Device ID уже используется!${NC}"
        return 1
    fi

    # Генерация параметров
    local mac=$(printf "02:%02X:%02X:%02X:%02X:%02X" $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)
    local port=$((30000 + RANDOM % 10000))
    local ip="10.$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%100+150))"

    # Запуск ноды
    {
        echo -e "${GREEN}[*] Установка ноды $node_name...${NC}"
        mkdir -p "/ag/$node_name" && cd "/ag/$node_name"
        eval "$cmd1" || exit 1
        eval "$cmd2" || exit 1
        
        docker run -d \
            --name "ag_$node_name" \
            --restart always \
            --mac-address "$mac" \
            --cpus 0.5 \
            --memory 1G \
            -p $port:$port \
            -v "$PWD:/data" \
            alpine/node:18 \
            sh -c "$cmd3 --http_port=$port" || exit 1

        USED_IDS["$device_id"]=1
        echo "$node_name|$device_id|$mac|$port|$ip" >> "$CONFIG_FILE"
    } 2>&1 | tee "/ag/$node_name/install.log"

    echo -e "${GREEN}[✓] Нода $node_name запущена!${NC}"
    sleep 1
}

setup_nodes() {
    while true; do
        read -p "Количество нод: " count
        [[ "$count" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}Ошибка: введите число > 0!${NC}"
    done

    for ((i=1; i<=count; i++)); do
        deploy_node $i
    done
}

node_status() {
    clear
    echo -e "${ORANGE}=== СТАТУС НОД ===${NC}"
    printf "%-20s | %-15s | %-17s | %s\n" "Имя" "Порт" "MAC" "Статус"
    
    while IFS='|' read -r name _ mac port _; do
        if docker ps | grep -q "ag_$name"; then
            status="${GREEN}🟢 ALIVE${NC}"
        else
            status="${RED}🔴 DEAD${NC}"
        fi
        printf "%-20s | %-15s | %-17s | %b\n" "$name" "$port" "$mac" "$status"
    done < "$CONFIG_FILE"
    
    read -p $'\nНажмите Enter...'
}

show_logs() {
    read -p "Имя ноды: " name
    echo -e "${ORANGE}=== ЛОГИ $name ===${NC}"
    docker logs --tail 50 "ag_$name" 2>&1 | ccze -A
    read -p $'\nНажмите Enter...'
}

restart_nodes() {
    echo -e "${ORANGE}[*] Перезапуск нод...${NC}"
    while IFS='|' read -r name _ _ _ _; do
        docker restart "ag_$name" >/dev/null
    done < "$CONFIG_FILE"
    echo -e "${GREEN}[✓] Ноды перезапущены!${NC}"
    sleep 1
}

nuke_system() {
    echo -e "${RED}[!] УНИЧТОЖЕНИЕ ВСЕХ ДАННЫХ [!]${NC}"
    docker ps -aq --filter "name=ag_" | xargs -r docker rm -f
    rm -rf /ag/*
    > "$CONFIG_FILE"
    echo -e "${GREEN}[✓] Система очищена!${NC}"
    sleep 1
}

# Инициализация
[ -f "$CONFIG_FILE" ] && while IFS='|' read -r _ id _ _ _; do
    USED_IDS["$id"]=1
done < "$CONFIG_FILE"

# Главный цикл
while true; do
    show_menu
    read -p "${ORANGE}Выбор:${NC} " choice
    case $choice in
        1) setup_nodes ;;
        2) node_status ;;
        3) show_logs ;;
        4) restart_nodes ;;
        5) nuke_system ;;
        6) exit 0 ;;
        *) echo -e "${RED}Неверный выбор!${NC}"; sleep 1 ;;
    esac
done
