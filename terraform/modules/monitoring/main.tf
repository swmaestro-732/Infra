data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_subnet" "this" {
  id = var.subnet_id
}

# ───────── Grafana admin 비밀번호 → Secrets Manager (RDS 패턴 재사용) ─────────
resource "random_password" "grafana_admin" {
  length  = 20
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name = "${var.name}/grafana/admin"
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.grafana_admin.result
  })
}

# ───────── 보안그룹 (모니터링 호스트) ─────────
# Grafana(3000)/Prometheus(9090)는 공개 인그레스 없음 → SSM 포트포워딩으로만 접근.
resource "aws_security_group" "monitoring" {
  name        = "${var.name}-monitoring-sg"
  description = "LGTM host - log/trace push from app tier; Grafana via SSM only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Loki log push from app"
    from_port       = 3100
    to_port         = 3100
    protocol        = "tcp"
    security_groups = [var.app_sg_id]
  }

  ingress {
    description     = "Tempo OTLP (gRPC/HTTP) from app"
    from_port       = 4317
    to_port         = 4318
    protocol        = "tcp"
    security_groups = [var.app_sg_id]
  }

  egress {
    description = "all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-monitoring-sg" }
}

# 앱 SG 에 "모니터링→앱 스크레이프(8080)" 인그레스를 단방향 추가 (SG 상호참조 순환 회피)
resource "aws_security_group_rule" "app_scrape_from_monitoring" {
  type                     = "ingress"
  description              = "Prometheus scrape from monitoring host"
  from_port                = var.app_port
  to_port                  = var.app_port
  protocol                 = "tcp"
  security_group_id        = var.app_sg_id
  source_security_group_id = aws_security_group.monitoring.id
}

# ───────── IAM (SSM 접속 + Prometheus EC2 SD + Grafana 시크릿 읽기) ─────────
resource "aws_iam_role" "monitoring" {
  name = "${var.name}-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Prometheus ec2_sd 가 앱 인스턴스를 발견하기 위한 읽기 전용 권한
resource "aws_iam_role_policy" "ec2_discovery" {
  name = "${var.name}-monitoring-ec2-sd"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "grafana_secret_read" {
  name = "${var.name}-monitoring-secret-read"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.grafana_admin.arn
    }]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.name}-monitoring-profile"
  role = aws_iam_role.monitoring.name
}

# ───────── 관측 데이터용 EBS (gp3, 암호화) ─────────
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.name}-monitoring-data" }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}

# ───────── 모니터링 호스트 (LGTM 스택, Docker) ─────────
locals {
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region          = var.aws_region
    grafana_secret_name = aws_secretsmanager_secret.grafana_admin.name
    loki_config         = file("${path.module}/templates/loki-config.yaml")
    tempo_config        = file("${path.module}/templates/tempo-config.yaml")
    mimir_config        = file("${path.module}/templates/mimir-config.yaml")
    grafana_ds          = file("${path.module}/templates/grafana-datasources.yaml")
    prometheus_cfg = templatefile("${path.module}/templates/prometheus.yml.tftpl", {
      region       = var.aws_region
      app_port     = var.app_port
      app_name_tag = var.app_name_tag
    })
    compose = templatefile("${path.module}/templates/docker-compose.yml.tftpl", {
      grafana_version = var.grafana_version
    })
  })
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 강제
    # Prometheus 컨테이너가 IMDS(인스턴스 역할 자격증명)로 ec2_sd 호출 → 컨테이너 1홉 여유 필요
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data = base64encode(local.user_data)

  tags = { Name = "${var.name}-monitoring" }
}
