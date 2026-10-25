packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
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

variable "vpc_id" {
  description = "빌드용 VPC. 빈 값이면 default VPC 사용"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "인터넷과 SSH 접근이 가능한 빌드용 퍼블릭 서브넷. 빈 값이면 Packer가 선택"
  type        = string
  default     = ""
}

source "amazon-ebs" "monitoring" {
  region        = var.region
  instance_type = var.instance_type
  communicator  = "ssh"
  ssh_username  = "ec2-user"

  vpc_id                                    = var.vpc_id
  subnet_id                                 = var.subnet_id
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

  provisioner "shell" {
    script          = "${path.root}/provision.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}
