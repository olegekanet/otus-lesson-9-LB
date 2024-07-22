terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.41"
}

provider "yandex" {
  zone = var.yandex_zone
}

# Создание виртуальной частной сети (VPC)
resource "yandex_vpc_network" "lab_net" {
  name = var.vpc_name
  #folder_id   = var.yandex_folder_id
  description = "Lab network in Yandex.Cloud"
}

# Создание подсети внутри VPC
resource "yandex_vpc_subnet" "lab_subnet" {
  zone           = var.yandex_zone
  network_id     = yandex_vpc_network.lab_net.id
  v4_cidr_blocks = var.v4_cidr_blocks_default # Замените на нужный диапазон CIDR для вашей сети
}

# Генерация публичного и приватного ключей SSH
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Запись публичного ключа SSH в файл
resource "local_file" "ssh_key_pub" {
  filename = "${path.module}/id_rsa.pub"
  content  = tls_private_key.ssh_key.public_key_openssh
}

# Запись приватного ключа SSH в файл
resource "local_file" "ssh_key_private" {
  filename        = "${path.module}/id_rsa"
  content         = tls_private_key.ssh_key.private_key_pem
  file_permission = "0600"
}

resource "local_file" "cloud_config" {
  depends_on = [
    local_file.ssh_key_pub
  ]

  filename = "${path.module}/cloud-config.yaml"
  content  = <<-EOT
    #cloud-config
    users:
      - name: ubuntu
        groups: sudo
        shell: /bin/bash
        sudo: 'ALL=(ALL) NOPASSWD:ALL'
        ssh_authorized_keys:
          - ${local_file.ssh_key_pub.content}
  EOT
}


# Создание виртуальных машин
resource "yandex_compute_instance" "vm_nginx" {
  count = var.nginx_count
  depends_on = [
    local_file.cloud_config
  ]
  name        = "nginx${count.index + 1}"
  zone        = var.yandex_zone
  platform_id = "standard-v2"
  resources {
    cores  = 2
    memory = 2
  }
  boot_disk {
    initialize_params {
      image_id = var.image_id
    }
  }

  network_interface {
    subnet_id  = yandex_vpc_subnet.lab_subnet.id
    nat        = true
    ip_address = var.nginx_static_ips[count.index] # Статический IP для iSCS
  }

  metadata = {
    user-data = "${file("./cloud-config.yaml")}"
  }

  labels = {
    environment = "production-laba"
    managered   = "terraform"
    lesson      = "9-lb"
  }
}


resource "yandex_compute_instance" "vm_backend" {
  count       = var.node_count
  depends_on  = [local_file.cloud_config]
  name        = "node${count.index + 1}"
  zone        = var.yandex_zone
  platform_id = "standard-v2"
  resources {
    cores  = 2
    memory = 2
  }
  boot_disk {
    initialize_params {
      image_id = var.image_id
    }
  }

  network_interface {
    subnet_id  = yandex_vpc_subnet.lab_subnet.id
    nat        = true
    ip_address = var.backend_static_ips[count.index]
  }

  metadata = {
    user-data = "${file("./cloud-config.yaml")}"
  }

  labels = {
    environment = "production-laba"
    managered   = "terraform"
    lesson      = "9-lb"
  }
}

# Создание дополнительного диска для iscsi
resource "yandex_compute_disk" "iscsi_disk" {
  zone = var.yandex_zone
  size = 10 # Размер диска в гигабайтах
  type = "network-hdd"
}

resource "yandex_compute_instance" "vm_db" {
  depends_on = [
    local_file.cloud_config
  ]
  name        = "db"
  zone        = var.yandex_zone
  platform_id = "standard-v2"
  resources {
    cores  = 2
    memory = 2
  }
  boot_disk {
    initialize_params {
      image_id = var.image_id
    }
  }

  network_interface {
    subnet_id  = yandex_vpc_subnet.lab_subnet.id
    nat        = true
    ip_address = var.db_static_ip # Статический IP для iSCS
  }

  metadata = {
    user-data = "${file("./cloud-config.yaml")}"
  }

  labels = {
    environment = "production-laba"
    managered   = "terraform"
    lesson      = "9-lb"
  }

  # вставляем iscsi_disk на машину с БД для экономии ресурсов 
  secondary_disk {
    disk_id = yandex_compute_disk.iscsi_disk.id
  }

}

# Создание файла hosts с указанием пути к приватному ключу SSH
resource "local_file" "hosts_file" {
  filename = "${path.module}/hosts"
  content  = <<-EOT
[nginx]
%{for idx in range(var.nginx_count)~}
${yandex_compute_instance.vm_nginx[idx].network_interface[0].nat_ip_address} ansible_ssh_user=ubuntu ansible_ssh_private_key_file="${path.module}/id_rsa"
%{endfor~}

%{for idx in range(var.nginx_count)~}
[nginx${idx + 1}]
${yandex_compute_instance.vm_nginx[idx].network_interface[0].nat_ip_address} ansible_ssh_user=ubuntu ansible_ssh_private_key_file="${path.module}/id_rsa"
%{endfor~}

[nodes]
%{for idx in range(var.node_count)~}
${yandex_compute_instance.vm_backend[idx].network_interface[0].nat_ip_address} ansible_ssh_user=ubuntu ansible_ssh_private_key_file="${path.module}/id_rsa"
%{endfor~}

%{for idx in range(var.node_count)~}
[node${idx + 1}]
${yandex_compute_instance.vm_backend[idx].network_interface[0].nat_ip_address} ansible_ssh_user=ubuntu ansible_ssh_private_key_file="${path.module}/id_rsa"
%{endfor~}

[db]
${yandex_compute_instance.vm_db.network_interface[0].nat_ip_address} ansible_ssh_user=ubuntu ansible_ssh_private_key_file="${path.module}/id_rsa"

EOT
}

# Определение ресурса null_resource для провижининга
resource "null_resource" "ansible_provisioner_nginx" {
  # Этот ресурс не представляет собой реальный ресурс, а используется только для провижионинга
  # Мы указываем зависимость от других ресурсов, чтобы Terraform выполнил этот ресурс после создания других ресурсов
  depends_on = [
    yandex_compute_instance.vm_nginx
  ]
  provisioner "local-exec" {
    command = "sleep 60" # Пауза в 10 секунд
  }
  # Команда, которая будет выполнена локально после создания ресурсов
  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook -i '${path.module}/hosts' -l nginx ${path.module}/playbook_nginx.yml"
  }
}


# Создание балансировщика нагрузки
resource "yandex_lb_network_load_balancer" "my_lb" {
  name        = "lbyandexotuslaba"
  description = "Load balancer for NGINX servers"
  #region_id   = var.yandex_zone
  listener {
    name        = "http"
    port        = 80
    target_port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.my_target_group.id
    healthcheck {
      name = "http"
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}

resource "yandex_lb_target_group" "my_target_group" {
  name = "my-target-group"

  target {
    address   = yandex_compute_instance.vm_nginx[0].network_interface[0].ip_address
    subnet_id = yandex_vpc_subnet.lab_subnet.id
  }

  target {
    address   = yandex_compute_instance.vm_nginx[1].network_interface[0].ip_address
    subnet_id = yandex_vpc_subnet.lab_subnet.id
  }
}

output "load_balancer_ip" {
  value = yandex_lb_network_load_balancer.my_lb.listener[*].external_address_spec[*].address
}




# Определение ресурса null_resource для провижининга
resource "null_resource" "ansible_provisioner_db" {
  # Этот ресурс не представляет собой реальный ресурс, а используется только для провижионинга
  # Мы указываем зависимость от других ресурсов, чтобы Terraform выполнил этот ресурс после создания других ресурсов
  depends_on = [
    yandex_compute_instance.vm_db
  ]
  provisioner "local-exec" {
    command = "sleep 60" # Пауза в 60 секунд (1 минута)
  }
  # Команда, которая будет выполнена локально после создания ресурсов
  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook -i '${path.module}/hosts' -l db ${path.module}/playbook_mysql.yml"
  }
  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook -i '${path.module}/hosts' -l db ${path.module}/setup_iscsi.yml"
  }
}

# Определение ресурса null_resource для провижининга
resource "null_resource" "ansible_provisioner_backend" {
  # Этот ресурс не представляет собой реальный ресурс, а используется только для провижионинга
  # Мы указываем зависимость от других ресурсов, чтобы Terraform выполнил этот ресурс после создания других ресурсов
  depends_on = [
    yandex_compute_instance.vm_backend,
    null_resource.ansible_provisioner_db
  ]
  provisioner "local-exec" {
    command = "sleep 60" # Пауза в 60 секунд (1 минута)
  }
  # Команда, которая будет выполнена локально после создания ресурсов
  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook -i '${path.module}/hosts' -l nodes ${path.module}/setup_gfs2.yml"
  }
  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook -i '${path.module}/hosts' -l nodes ${path.module}/playbook_project.yml"
  }

}


# Вывод сообщения в консоль после выполнения всех ресурсов
resource "null_resource" "final_message" {
  depends_on = [
    null_resource.ansible_provisioner_nginx,
    null_resource.ansible_provisioner_db,
    null_resource.ansible_provisioner_backend
  ]

  # provisioner "local-exec" {
  #   command = "echo 'Добавьте запись: ${yandex_compute_instance.vm_nginx.network_interface[0].nat_ip_address} test1.com  в файл /etc/hosts'"
  # }
}
