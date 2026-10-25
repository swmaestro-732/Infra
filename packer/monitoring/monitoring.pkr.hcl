packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.1"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

source "amazon-ebs" "monitoring" {
  region        = var.region
  instance_type = var.instance_type
  communicator  = "ssh"
  ssh_username  = "ec2-user"

  # 이 계정엔 default VPC 가 없으므로 태그로 chilsami VPC + 퍼블릭 서브넷(IGW 라우트)을 자동 발견한다.
  # 퍼블릭 서브넷 + associate_public_ip_address 로 빌드 인스턴스가 공인 IP·인터넷(dnf·이미지 pull)·SSH 가능.
  vpc_filter {
    filters = { "tag:Name" = "chilsami-vpc" }
  }
  subnet_filter {
    filters   = { "tag:Name" = "chilsami-public-*" }
    most_free = true
    random    = false
  }
  associate_public_ip_address               = true
  ssh_interface                             = "public_ip"
  temporary_security_group_source_public_ip = true

  source_ami_filter {
    filters = {
      name                  = "al2023-ami-*-x86_64"
      "virtualization-type" = "hvm"
      "root-device-type"    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  # swap + 이미지 캐시 공간을 확보하고 운영 호스트의 20GB 루트 볼륨에 맞춘다.
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  ami_name = "chilsami-monitoring-golden-{{timestamp}}"
  tags = {
    Name      = "chilsami-monitoring-golden"
    Component = "monitoring"
    BaseOS    = "al2023"
    ManagedBy = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.monitoring"]

  # Ansible 로 베이크한다(shell 대비 선언적·재사용 — 향후 앱 golden AMI 시 role 추가로 확장).
  # use_proxy=false: Packer SSH 프록시 대신 직접 접속(신뢰성). AL2023 는 python3 기본 포함(ansible 요건).
  provisioner "ansible" {
    playbook_file    = "${path.root}/ansible/playbook.yml"
    user             = "ec2-user"
    use_proxy        = false
    ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
  }
}
