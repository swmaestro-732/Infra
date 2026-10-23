# 채팅 메시지 영속 저장소(MongoDB 호환 DocumentDB). Redis 는 실시간 팬아웃 버스, 여기엔 메시지 원본을
# 저장하고 재접속 시 백필한다. 스토리지는 6-way(3 AZ) 복제라 단일 인스턴스여도 데이터 내구성은 보장되고
# 컴퓨트만 비HA(비용 절감, 채팅 MVP). DocumentDB 는 IAM 인증 미지원 → master user/password + TLS 필수.

resource "aws_docdb_subnet_group" "this" {
  name       = "${var.name}-docdb"
  subnet_ids = var.subnet_ids
}

# 앱 티어만 27017 허용. inline 단일 소스(inline+standalone 혼용 금지 — monitoring SG 교훈).
resource "aws_security_group" "docdb" {
  name        = "${var.name}-docdb-sg"
  description = "DocumentDB from app tier only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "DocumentDB 27017 from app tier"
    from_port       = 27017
    to_port         = 27017
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

  tags = { Name = "${var.name}-docdb-sg" }
}

# TLS 강제(평문 접속 금지). 앱은 AWS global CA 번들로 검증해 접속한다.
resource "aws_docdb_cluster_parameter_group" "this" {
  family      = "docdb5.0"
  name        = "${var.name}-docdb"
  description = "DocumentDB TLS enforced"

  parameter {
    name  = "tls"
    value = "enabled"
  }
}

# master 비번 — DocumentDB 는 생성 시 비번이 필수라 TF 가 생성한다(tfstate 는 암호화 S3). IAM 인증 미지원.
resource "random_password" "master" {
  length  = 24
  special = false
}

resource "aws_docdb_cluster" "this" {
  cluster_identifier              = "${var.name}-docdb"
  engine                          = "docdb"
  engine_version                  = var.engine_version
  master_username                 = "chilsami_admin"
  master_password                 = random_password.master.result
  db_subnet_group_name            = aws_docdb_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.docdb.id]
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.this.name

  backup_retention_period = var.backup_retention_days
  preferred_backup_window = "17:00-18:00" # UTC = KST 02:00~03:00

  storage_encrypted   = true
  deletion_protection = true # 데이터 저장소 — 실수 삭제 방지(해제해야 destroy 가능)
  skip_final_snapshot = true # deletion_protection 이 1차 가드. 필요 시 final snapshot 로 전환.

  apply_immediately = false

  lifecycle {
    ignore_changes = [master_password] # 회전은 Secrets Manager/콘솔로(재생성 방지)
  }
}

resource "aws_docdb_cluster_instance" "this" {
  count              = 1
  identifier         = "${var.name}-docdb-${count.index}"
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = var.instance_class
  apply_immediately  = false
}

# 접속 자격증명 시크릿(host/reader/port/user/password). 앱이 읽어 Mongo 클라이언트로 접속.
resource "aws_secretsmanager_secret" "creds" {
  name        = "${var.name}/docdb/credentials"
  description = "DocumentDB 접속 자격증명 (TF 관리) — host/reader/port/username/password"
}

resource "aws_secretsmanager_secret_version" "creds" {
  secret_id = aws_secretsmanager_secret.creds.id
  secret_string = jsonencode({
    host     = aws_docdb_cluster.this.endpoint
    reader   = aws_docdb_cluster.this.reader_endpoint
    port     = aws_docdb_cluster.this.port
    username = aws_docdb_cluster.this.master_username
    password = random_password.master.result
  })
}

# 앱 역할에 접속 자격증명 시크릿 read(최소권한).
resource "aws_iam_role_policy" "app_secret_read" {
  count = var.app_role_name != null ? 1 : 0
  name  = "${var.name}-docdb-secret-read"
  role  = var.app_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.creds.arn
    }]
  })
}
