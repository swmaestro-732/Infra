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
# audit_logs: 연결/DCL/DDL/인증 이벤트를 감사 로그로 남겨 CloudWatch 로 내보낸다(아래 클러스터 export).
resource "aws_docdb_cluster_parameter_group" "this" {
  family      = "docdb5.0"
  name        = "${var.name}-docdb"
  description = "DocumentDB TLS enforced + audit logs"

  parameter {
    name  = "tls"
    value = "enabled"
  }

  parameter {
    name  = "audit_logs"
    value = "enabled"
  }
}

# master 비번 — DocumentDB 는 생성 시 비번이 필수라 TF 가 생성한다(tfstate 는 암호화 S3). IAM 인증 미지원.
# 회전: keepers 를 바꾸면 새 비번 생성 → 클러스터·시크릿이 같은 apply 에서 함께 갱신(단일 진실원). 콘솔 수동 회전 금지.
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

  # 감사 로그를 CloudWatch Logs 로 내보낸다(파라미터 그룹 audit_logs=enabled 와 짝).
  enabled_cloudwatch_logs_exports = ["audit"]

  backup_retention_period = var.backup_retention_days
  preferred_backup_window = "17:00-18:00" # UTC = KST 02:00~03:00

  storage_encrypted   = true
  deletion_protection = true # 데이터 저장소 — 실수 삭제 방지(해제해야 destroy 가능)
  # 채팅 메시지 원본이라 destroy 시 최종 스냅샷을 남긴다(deletion_protection 은 1차 가드, 스냅샷은 2차 복구선).
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-docdb-final"

  apply_immediately = false
  # master_password 는 ignore_changes 하지 않는다 — random_password.master.result 를 클러스터·시크릿 단일 진실원으로
  # 삼아 항상 일치시킨다(회전 경로 정렬). keepers 없는 random_password 는 apply 간 안정적이라 churn 없음.

  # Name 태그 — CloudWatch Exporter 가 tag_Name 으로 내보내고 대시보드가 {tag_Name!=""} 로 필터하므로 필수.
  tags = { Name = "${var.name}-docdb" }
}

resource "aws_docdb_cluster_instance" "this" {
  count              = 1
  identifier         = "${var.name}-docdb-${count.index}"
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = var.instance_class
  apply_immediately  = false

  tags = { Name = "${var.name}-docdb-${count.index}" }
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
