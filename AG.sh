#!/bin/bash
# Alliance Games Node Manager (Titan-style)
# GitHub: https://github.com/your-repo

GREEN='\033[0;32m'
ORANGE='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'
CONFIG_FILE="/etc/ag_nodes.conf"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/ag_logo"

show_logo() {
  clear
  echo -ne "${ORANGE}"
  curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== AG NODE MANAGER ==="
  echo -e "${NC}\n"
}

validate_command() {
  local cmd="$1"
  [[ "$cmd" =~ ^curl.*launcher.*worker$ ]] && return 0
  [[ "$cmd" =~ ^chmod.*launcher.*worker$ ]] && return 0
  [[ "$cmd" =~ ^\./launcher.*device_id= ]] && return 0
  return 1
}

deploy_single_node() {
  local node_name device_id
  while true; do
    show_logo
    echo -e "${ORANGE}=== РУКОВОДСТВО ===${NC}"
    echo "1. Скопируйте ТРИ команды с сайта:"
    echo -e "   ${GREEN}curl...\n   chmod...\n   ./launcher...${NC}\n"

    read -p "${ORANGE}1/3 Введите команду загрузки (curl):${NC} " cmd1
    read -p "${ORANGE}2/3 Введите команду прав доступа (chmod):${NC} " cmd2
    read -p "${ORANGE}3/3 Введите команду запуска (./launcher):${NC} " cmd3

    if validate_command "$cmd1" && validate_command "$cmd2" && validate_command "$cmd3"; then
      device_id=$(grep -oP "device_id=\K[^ ]+" <<< "$cmd3")
      [ ! -z "${USED_IDS[$device_id]}" ] && echo -e "${RED}Ошибка: Этот ID уже используется!${NC}" && continue
      node_name=$(grep -oP "device_name=\K[^ ]+" <<< "$cmd3")
      break
    else
      echo -e "${RED}Неверный формат! Сверьтесь с примером:"
      echo -e "curl -L .../launcher -o launcher && curl -L .../worker -o worker"
      echo -e "./launcher --user_did=... --device_id=... --device_name=...${NC}"
      sleep 3
    fi
  done

  # Генерация параметров
  local mac=$(printf "02:%02x:%02x:%02x:%02x:%02x" $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)
  local port=$((30000 + RANDOM % 10000))
  local ip="10.$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%100+150))"

  # Запись логов
  mkdir -p "/ag/$node_name"
  (
    echo -e "${GREEN}[$(date)] Начало установки${NC}"
    cd "/ag/$node_name"
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

    echo "$node_name|$device_id|$mac|$port|$ip" >> "$CONFIG_FILE"
    USED_IDS["$device_id"]=1
  ) 2>&1 | tee "/ag/$node_name/install.log"

  echo -e "\n${GREEN}Нода ${node_name} запущена!${NC}"
  sleep 2
}

node_status() {
  show_logo
  printf "${ORANGE}%-20s | %-15s | %-17s | %s${NC}\n" "Имя" "Порт" "MAC" "Статус"
  
  while IFS='|' read -r name _ mac port _; do
    if docker ps | grep -q "ag_$name"; then
      status="${GREEN}🟢${NC}"
    else
      status="${RED}🔴${NC}"
    fi
    printf "%-20s | %-15s | %-17s | %b\n" "$name" "$port" "$mac" "$status"
  done < "$CONFIG_FILE"
  
  read -p $'\nНажмите Enter...'
}

bulk_deploy() {
  show_logo
  read -p "${ORANGE}Количество нод:${NC} " count
  for ((i=1; i<=count; i++)); do
    deploy_single_node
  done
}

nuke_all() {
  show_logo
  echo -e "${RED}=== ПОЛНАЯ ОЧИСТКА ===${NC}"
  docker ps -aq --filter "name=ag_" | xargs -r docker rm -f
  rm -rf /ag/*
  > "$CONFIG_FILE"
  echo -e "${GREEN}Все ноды удалены!${NC}"
  sleep 1
}

show_menu() {
  while true; do
    show_logo
    echo -e "1) Установить ноды\n2) Массовая установка\n3) Статус нод\n4) Удалить всё\n5) Выход"
    read -p "${ORANGE}Выбор:${NC} " choice
    
    case $choice in
      1) deploy_single_node ;;
      2) bulk_deploy ;;
      3) node_status ;;
      4) nuke_all ;;
      5) exit 0 ;;
      *) echo -e "${RED}Неверный выбор!${NC}"; sleep 1 ;;
    esac
  done
}

# Инициализация
declare -A USED_IDS=()
[ -f "$CONFIG_FILE" ] && while IFS='|' read -r _ id _ _ _; do
  USED_IDS["$id"]=1
done < "$CONFIG_FILE"

show_menu
