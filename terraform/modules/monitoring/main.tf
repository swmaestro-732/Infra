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
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.grafana_admin.arn,
        var.slack_webhook_secret_arn, # Slack 알림 웹훅(환경에서 생성해 ARN 주입 — 같은 apply 라 data 조회 불가)
      ]
    }]
  })
}

# CloudWatch Exporter 가 AWS 지표(EC2/RDS/ALB 등)를 CloudWatch API 로 pull → Prometheus 유입.
# 읽기 전용(GetMetricData/ListMetrics) + 태그 리소스 발견. Resource="*"는 CloudWatch API 특성상 불가피.
resource "aws_iam_role_policy" "cloudwatch_read" {
  name = "${var.name}-monitoring-cloudwatch-read"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
        "tag:GetResources",
      ]
      Resource = "*"
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
    aws_region                  = var.aws_region
    grafana_secret_name         = aws_secretsmanager_secret.grafana_admin.name
    slack_webhook_secret_name   = var.slack_webhook_secret_name
    loki_config                 = file("${path.module}/templates/loki-config.yaml")
    tempo_config                = file("${path.module}/templates/tempo-config.yaml")
    mimir_config                = file("${path.module}/templates/mimir-config.yaml")
    grafana_ds                  = file("${path.module}/templates/grafana-datasources.yaml")
    grafana_dashboards_provider = file("${path.module}/templates/grafana-dashboards.yaml")
    # Grafana 통합알림 프로비저닝(contact point/정책/규칙). file()로 읽어 Terraform 미보간
    # (contactpoints 의 ${SLACK_WEBHOOK_URL}는 Grafana 가 env 로 치환).
    grafana_alert_contactpoints = file("${path.module}/templates/grafana-alerting-contactpoints.yaml")
    grafana_alert_policies      = file("${path.module}/templates/grafana-alerting-policies.yaml")
    grafana_alert_rules         = file("${path.module}/templates/grafana-alerting-rules.yaml")
    cloudwatch_config = templatefile("${path.module}/templates/cloudwatch-exporter.yml.tftpl", {
      region = var.aws_region
    })
    # 대시보드 JSON (커뮤니티 임포트) — 파일명 → 내용 맵. user_data 가 각 파일을 배치한다.
    dashboards = {
      for f in fileset("${path.module}/dashboards", "*.json") :
      f => file("${path.module}/dashboards/${f}")
    }
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

# 고정 사설 IP를 갖는 전용 ENI. 인스턴스가 교체(AMI 드리프트·user_data 변경)돼도 이 ENI를
# 재부착해 IP가 불변 → 앱(로그/트레이스 push 대상)이 부팅 때 읽은 IP가 스테일되지 않는다.
# subnet_id/security_groups 는 ENI 로 이동(인스턴스에 network_interface 를 붙이면 인스턴스 쪽엔 못 둠).
resource "aws_network_interface" "monitoring" {
  subnet_id       = var.subnet_id
  security_groups = [aws_security_group.monitoring.id]

  tags = { Name = "${var.name}-monitoring-eni" }
}

resource "aws_instance" "this" {
  ami                  = data.aws_ssm_parameter.al2023.value
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.monitoring.name

  network_interface {
    network_interface_id = aws_network_interface.monitoring.id
    device_index         = 0
  }

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

  # user_data_base64 로 전달: aws_instance 의 user_data 인자는 넘긴 문자열(=base64) 길이를 16384 와
  # 비교하므로 실효 한도가 ~12KB 로 줄어든다. user_data_base64 는 디코딩된 raw(≤16384)를 검증해 여유가 크고,
  # base64/cloud-init 처리도 명시적으로 올바르다.
  user_data_base64 = base64encode(local.user_data)

  # user_data 는 부팅(cloud-init) 때만 실행된다. 이 인스턴스는 ASG 가 아니라 단독 인스턴스라
  # user_data(설정/대시보드/compose) 를 바꿔도 이 옵션이 없으면 기존 호스트에 반영되지 않는다.
  # true 로 두어 user_data 변경 시 인스턴스를 재생성(재프로비저닝)한다. 관측 데이터는 별도 EBS(/data)라 보존됨.
  user_data_replace_on_change = true

  # user_data 가 부팅 시 시크릿을 조회하므로 선행 리소스를 명시한다:
  #  - grafana 비번 secret version: 인스턴스는 secret 이름만 참조해 version 생성 순서가 안 보장됨.
  #  - secret_read IAM 정책: instance_profile→role 의존만으론 role 인라인 정책 적용 순서가 안 보장돼
  #    부팅 시 GetSecretValue 가 권한 전파 前 실패할 수 있음(재시도는 user_data 에도 추가).
  depends_on = [
    aws_secretsmanager_secret_version.grafana_admin,
    aws_iam_role_policy.grafana_secret_read,
  ]

  tags = { Name = "${var.name}-monitoring" }
}

# 앱(ec2 모듈)이 로그/트레이스 push 대상 IP 를 부팅 시 조회하도록 private IP 를 SSM 에 기록.
# 이름을 넘겨받아 순환 의존을 회피(모듈 간 output 직접 참조 안 함).
resource "aws_ssm_parameter" "host" {
  count = var.host_ssm_param_name == "" ? 0 : 1

  name = var.host_ssm_param_name
  type = "String"
  # 인스턴스가 아니라 ENI 의 IP(불변)를 기록 → 모니터링 호스트 교체돼도 값이 안 바뀐다.
  value = aws_network_interface.monitoring.private_ip
}
