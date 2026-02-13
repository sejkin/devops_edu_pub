#!/bin/bash

# =============================================================================
# Полностью автоматизированное развёртывание 4 ВМ (VM1, VM2, VM3, Bastion)
# с двумя bridge-интерфейсами и автоматической установкой Ubuntu (unattended install)
# =============================================================================

set -e  # Прерывать выполнение при любой ошибке

# ------------------------------ НАСТРОЙКИ ------------------------------
VM_NAMES=("VM1.local" "VM2.local" "VM3.local" "Bastion.local")          # Имена машин
VM_MEMORY=2048                                   # ОЗУ (МБ)
VM_CPUS=2                                        # Ядра CPU
VM_HDD_SIZE=20000                                # Диск 20 ГБ
VM_OSTYPE="Ubuntu_64"                            # Тип гостевой ОС
VM_BASE_DIR="/d/Data/VM/"               # Папка для дисков

# Учётные данные (будут использованы в unattended install)
UBUNTU_USER="ubuntu"
UBUNTU_PASSWORD="ubuntu"

# Параметры сетей (статическая конфигурация, которая будет применена после установки)
GATEWAY1="10.10.0.1"
GATEWAY2="192.168.100.1"
DNS_SERVERS="8.8.8.8 8.8.4.4"

# Распределение IP:
#   Bastion : 10.10.0.10    , 192.168.100.10
#   VM1     : 10.10.0.100   , 192.168.100.100
#   VM2     : 10.10.0.101   , 192.168.100.101
#   VM3     : 10.10.0.102   , 192.168.100.102
declare -A VM_IPS
VM_IPS["VM1"]="10.10.0.100 192.168.100.100"
VM_IPS["VM2"]="10.10.0.101 192.168.100.101"
VM_IPS["VM3"]="10.10.0.102 192.168.100.102"
VM_IPS["Bastion"]="10.10.0.10 192.168.100.10"

UBUNTU_ISO_PATH="/d/Data/Distrib/ubuntu-24.04.3-live-server-amd64.iso"

# Интерфейс хоста для bridge (определяется автоматически, но можно задать вручную)
HOST_BRIDGE_IF="MediaTek Wi-Fi 6 MT7921 Wireless LAN Card"

# Время ожидания завершения установки (секунд)
INSTALL_WAIT=240
# ---------------------------------------------------------------------


# ---------------------------------------------------------------------
# Функция создания одной ВМ и запуска unattended install
create_and_install() {
    local VM_NAME="$1"
    local VM_DIR="$VM_BASE_DIR/$VM_NAME"
    local HDD_PATH="$VM_DIR/$VM_NAME.vdi"

    echo ">>> [${VM_NAME}] Создание виртуальной машины..."

    # Удаляем предыдущую ВМ с таким именем, если она есть (без подтверждения)
    ./VBoxManage unregistervm "$VM_NAME" --delete 2>/dev/null || true

    # Регистрация
    ./VBoxManage createvm --name "$VM_NAME" --ostype "$VM_OSTYPE" --register

    # Настройка параметров (два bridge-адаптера)
    ./VBoxManage modifyvm "$VM_NAME" \
        --memory "$VM_MEMORY" \
        --cpus "$VM_CPUS" \
        --acpi on \
        --boot1 disk --boot2 dvd \
        --graphicscontroller vmsvga \
        --nic1 bridged --bridgeadapter1 "$HOST_BRIDGE_IF" \
        --nic2 bridged --bridgeadapter2 "$HOST_BRIDGE_IF"

    # Создание диска
    mkdir -p "$VM_DIR"
    ./VBoxManage createhd --filename "$HDD_PATH" --size "$VM_HDD_SIZE" --format VDI

    # Контроллер SATA + диск
    ./VBoxManage storagectl "$VM_NAME" --name "SATA Controller" --add sata --controller IntelAhci
    ./VBoxManage storageattach "$VM_NAME" \
        --storagectl "SATA Controller" \
        --port 0 --device 0 \
        --type hdd --medium "$HDD_PATH"

    # Контроллер IDE + ISO (пока без второго привода)
    ./VBoxManage storagectl "$VM_NAME" --name "IDE Controller" --add ide
    ./VBoxManage storageattach "$VM_NAME" \
        --storagectl "IDE Controller" \
        --port 0 --device 0 \
        --type dvddrive --medium "$UBUNTU_ISO_PATH"

    # Запуск автоматической установки
    echo ">>> [${VM_NAME}] Запуск unattended install..."
    ./VBoxManage unattended install "$VM_NAME" --iso="$UBUNTU_ISO_PATH" --user="$UBUNTU_USER" \
        --password="$UBUNTU_PASSWORD" \
        --hostname="$VM_NAME" \
        --install-additions \
        --start-vm=headless

    echo ">>> [${VM_NAME}] Установка запущена в фоновом режиме."
}

# ---------------------------------------------------------------------
# Функция получения MAC-адреса первого интерфейса ВМ
get_mac() {
    local VM_NAME="$1"
    ./VBoxManage showvminfo "$VM_NAME" --machinereadable | grep '^macaddress1=' | cut -d'=' -f2 | tr -d '"'
}

# Функция ожидания IP по MAC
wait_for_ip() {
    local MAC="$1"
    local MAX_ATTEMPTS=30
    local ATTEMPT=0
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        # arp-scan требует sudo, но можно использовать sudo без пароля или настроить
        IP=$(sudo arp-scan --localnet --numeric --quiet | grep -i "$MAC" | awk '{print $1}')
        if [ -n "$IP" ]; then
            echo "$IP"
            return 0
        fi
        sleep 10
        ATTEMPT=$((ATTEMPT + 1))
    done
    return 1
}

# ---------------------------------------------------------------------
# 1. СОЗДАНИЕ И УСТАНОВКА ВСЕХ ВМ
echo "========================================================================="
echo "ЗАПУСК СОЗДАНИЯ 4 ВИРТУАЛЬНЫХ МАШИН (VM1, VM2, VM3, Bastion)"
echo "========================================================================="

for VM_NAME in "${VM_NAMES[@]}"; do
    create_and_install "$VM_NAME"
done

echo ">>> Ожидание $INSTALL_WAIT секунд для завершения установки..."
sleep "$INSTALL_WAIT"

# ---------------------------------------------------------------------
# 2. ПОЛУЧЕНИЕ IP-АДРЕСОВ ВМ (ЧЕРЕЗ ARP-SCAN)
echo ">>> Получение IP-адресов виртуальных машин (поиск по MAC)..."

declare -A VM_IP_DHCP  # ассоциативный массив: имя ВМ -> временный IP

for VM_NAME in "${VM_NAMES[@]}"; do
    MAC=$(get_mac "$VM_NAME")
    echo "   $VM_NAME MAC: $MAC"
    IP=$(wait_for_ip "$MAC")
    if [ -n "$IP" ]; then
        VM_IP_DHCP["$VM_NAME"]="$IP"
        echo "   -> найден IP: $IP"
    else
        echo "   -> НЕ удалось получить IP для $VM_NAME. Проверьте вручную."
        exit 1
    fi
done

# ---------------------------------------------------------------------
# 3. НАСТРОЙКА ВМ ЧЕРЕЗ SSH
echo ">>> Настройка виртуальных машин (статический IP, пользователи, UFW)..."

# Функция выполнения команд на удалённой машине
remote_exec() {
    local VM_NAME="$1"
    local TARGET_IP="${VM_IP_DHCP[$VM_NAME]}"
    shift
    sshpass -p "$UBUNTU_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${UBUNTU_USER}@${TARGET_IP}" "$@"
}

# Функция копирования файла
remote_copy() {
    local SRC="$1"
    local VM_NAME="$2"
    local DEST="$3"
    local TARGET_IP="${VM_IP_DHCP[$VM_NAME]}"
    sshpass -p "$UBUNTU_PASSWORD" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SRC" "${UBUNTU_USER}@${TARGET_IP}:$DEST"
}

# Настройка статического IP через Netplan
setup_netplan() {
    local VM_NAME="$1"
    local IPS=(${VM_IPS[$VM_NAME]})
    local IP1="${IPS[0]}"
    local IP2="${IPS[1]}"
    local NETPLAN_FILE="/tmp/99-${VM_NAME}.yaml"

    cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: false
      addresses:
        - ${IP1}/16
      routes:
        - to: default
          via: ${GATEWAY1}
      nameservers:
        addresses: [${DNS_SERVERS}]
    enp0s8:
      dhcp4: false
      addresses:
        - ${IP2}/24
      routes:
        - to: default
          via: ${GATEWAY2}
      nameservers:
        addresses: [${DNS_SERVERS}]
EOF

    remote_copy "$NETPLAN_FILE" "$VM_NAME" "/tmp/99-${VM_NAME}.yaml"
    remote_exec "$VM_NAME" "sudo mv /tmp/99-${VM_NAME}.yaml /etc/netplan/ && sudo netplan apply"
    echo "   $VM_NAME: статические IP ${IP1}, ${IP2} настроены."
}

# Создание пользователя devops с UID/GID 2000
create_devops_user() {
    local VM_NAME="$1"
    remote_exec "$VM_NAME" "
        sudo groupadd -g 2000 devops || true
        sudo useradd -u 2000 -g 2000 -G sudo -m -s /bin/bash devops || true
        echo 'devops:$UBUNTU_PASSWORD' | sudo chpasswd
        echo 'devops ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/devops
    "
    echo "   $VM_NAME: пользователь devops создан."
}

# Настройка UFW на целевых машинах (VM1-3) – разрешить SSH только с Bastion
setup_ufw() {
    local VM_NAME="$1"
    local BASTION_IP1="10.10.0.10"
    local BASTION_IP2="192.168.100.10"
    remote_exec "$VM_NAME" "
        sudo ufw --force reset
        sudo ufw default deny incoming
        sudo ufw allow from $BASTION_IP1 to any port 22
        sudo ufw allow from $BASTION_IP2 to any port 22
        sudo ufw --force enable
    "
    echo "   $VM_NAME: UFW настроен (доступ только с Bastion)."
}

# Выполняем настройки для всех машин
for VM_NAME in "${VM_NAMES[@]}"; do
    echo "--- Настройка $VM_NAME ---"
    setup_netplan "$VM_NAME"
    create_devops_user "$VM_NAME"
done

# Для VM1-3 дополнительно UFW
for VM_NAME in "${VM_NAMES[@]}"; do
    if [[ "$VM_NAME" =~ ^VM[1-3]$ ]]; then
        setup_ufw "$VM_NAME"
    fi
done

# На Bastion включим IP forwarding (на всякий случай)
remote_exec "Bastion" "sudo sysctl -w net.ipv4.ip_forward=1 && echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf"

echo "========================================================================="
echo "ГОТОВО. Все виртуальные машины созданы, установлены и настроены."
echo "========================================================================="
echo "Итоговые IP:"
for VM_NAME in "${VM_NAMES[@]}"; do
    IPS=(${VM_IPS[$VM_NAME]})
    echo "  $VM_NAME : ${IPS[0]} (10.10.0.0/16), ${IPS[1]} (192.168.100.0/24)"
done
echo ""
echo "Подключайтесь к Bastion (предварительно убедитесь, что хост имеет доступ к сетям 10.10.0.0/16 и 192.168.100.0/24):"
echo "  ssh ubuntu@10.10.0.10"
echo "Пароль: ubuntu"
echo "Затем с Bastion к целевым машинам:"
echo "  ssh ubuntu@10.10.0.100   # или 192.168.100.100"
echo ""
echo "Пользователь devops (UID/GID 2000) создан на всех машинах с тем же паролем."