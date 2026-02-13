При выполнеии домашнего задания пытался изучал механизм автоматизации развёртывания виртуальных машин с virtualbox

ОС Windows 10
Установил virtualbox и установил Ubuntu Server
Установил Gitbash для Windows

Попытался найти информацию для развёртывания VM и автоматической настройки через VBoxManager

В Windows столкнулся с необходимостью указания переменной окружения или необходимость вызывать ./VBoxManager

Автоматический запуск установки прерывался на ошибке
VBoxManage Incomplete hostname - must include both a name and a domain

Задал имена виртуалкам с доменом в конце. После этого
VBoxManage unattended install "VM1" --iso="/d/Data/Distrib/ubuntu-24.04.3-live-server-amd64.iso" --user="ubuntu"--password="ubuntu" --hostname="$VM_NAME" --install-additions --start-vm=headless
выполняется без ошибок и запускает установку.

В итоге виртуальные машины создаются, но автоматическая установка останавливается на выборе языка.


Поднял VirtualBox на виртуальной машине и попытался выполнить скрипт там. В итоге виртуальные машины создаются, но при запуске ошибка, что тип процессора не поддерживается.

Так же необходимо было узнать наименование текущего bridge через VBoxManage list bridgedifs и задать его в скрипте явно

После доустановки вручную добавлен доступ по ssh 
сгенерировал на ubuntu для установки пару ключей и скопировал из папки /.ssh через ssh-copy-id -i id_rsa.pub ubuntu@10.10.0.100

Добавил дополнительный диск
pvcreate /dev/sdb
vgextend ubuntu-vg /dev/sdb
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
resize2fs /dev/ubuntu-vg/ubuntu-lv


