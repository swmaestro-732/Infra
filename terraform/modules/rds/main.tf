resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnets"
  subnet_ids = var.data_subnet_ids

  tags = { Name = "${var.name}-db-subnets" }
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "RDS PostgreSQL from app tier only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from app"
    from_port       = 5432
    to_port         = 5432
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

  tags = { Name = "${var.name}-rds-sg" }
}

# ───────── 자격증명 (생성 후 Secrets Manager 보관) ─────────
resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name = "${var.name}/rds/credentials"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username    = var.username
    password    = random_password.db.result
    dbname      = var.db_name
    writer_host = aws_db_instance.primary.address
    reader_host = try(aws_db_instance.replica[0].address, aws_db_instance.primary.address)
    writer_az   = var.writer_az
    port        = 5432
  })
}

# ───────── 파라미터 그룹 (PostgreSQL: timezone / 인코딩) ─────────
# PG 기본 인코딩은 UTF8이라 MySQL식 character_set_* 는 불필요.
resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-pg"
  family      = var.parameter_group_family
  description = "chilsami PostgreSQL params (KST timezone, UTF8)"

  parameter {
    name  = "timezone"
    value = var.timezone
  }

  parameter {
    name  = "client_encoding"
    value = "UTF8"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ───────── Writer (단일 AZ 고정 — standby 대신 cross-AZ reader 운용) ─────────
# multi_az=true 면 standby 자동, availability_zone 은 무시(null). false 면 writer_az 에 고정.
resource "aws_db_instance" "primary" {
  identifier        = "${var.name}-rds-writer"
  engine            = "postgres"
  engine_version    = var.engine_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_encrypted = true

  db_name  = var.db_name
  username = var.username
  password = random_password.db.result

  multi_az               = var.multi_az
  availability_zone      = var.multi_az ? null : var.writer_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  skip_final_snapshot        = true
  deletion_protection        = false
  apply_immediately          = true

  tags = { Name = "${var.name}-rds-writer" }
}

# ───────── Read Replica (동일 리전, 읽기 분산) ─────────
resource "aws_db_instance" "replica" {
  count = var.create_read_replica ? 1 : 0

  identifier             = "${var.name}-rds-reader"
  replicate_source_db    = aws_db_instance.primary.identifier
  instance_class         = var.instance_class
  availability_zone      = var.reader_az
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot = true
  deletion_protection = false

  tags = { Name = "${var.name}-rds-reader" }
}

# ───────── 앱(EC2) 에 이 시크릿만 읽기 권한 (최소권한) ─────────
resource "aws_iam_role_policy" "app_secret_read" {
  count = var.app_role_name != null ? 1 : 0
  name  = "${var.name}-rds-secret-read"
  role  = var.app_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}
