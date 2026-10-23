# 채팅 실시간 팬아웃용 ElastiCache(Valkey). 메시지 저장이 아니라 Pub/Sub 버스 전용이라
# 데이터는 비영속(백업 불필요). EC2 2대가 각각 구독해 자기 WebSocket 세션에 팬아웃한다.
# in-transit TLS + AUTH 토큰 필수(앱은 rediss:// + 토큰). 모니터링 호스트와 분리된 전용 노드.

# ───────── 서브넷 그룹 (검색·캐시 티어, 프라이빗) ─────────
resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-redis"
  subnet_ids = var.subnet_ids
}

# ───────── 보안그룹 (앱 티어만 6379 허용, inline 단일 소스) ─────────
# inline + standalone rule 혼용은 perpetual diff 를 만든다(monitoring SG 교훈) → 인라인으로만 관리.
resource "aws_security_group" "redis" {
  name        = "${var.name}-redis-sg"
  description = "Redis(Valkey) from app tier only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis TLS from app and extra client SGs"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = concat([var.app_sg_id], var.extra_ingress_sg_ids)
  }

  egress {
    description = "all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-redis-sg" }
}

# ───────── IAM 인증 (RBAC user + user group, 장기 비번 없음) ─────────
# 앱은 인스턴스 역할로 15분짜리 SigV4 토큰을 생성해 AUTH 비번 자리에 넣는다(OpenSearch SigV4 와 같은 결).
# IAM 유저는 user_name == user_id 여야 한다(ElastiCache 제약). 앱은 이 user_name 으로 접속.
resource "aws_elasticache_user" "app" {
  user_id       = "${var.name}-chat-app"
  user_name     = "${var.name}-chat-app"
  engine        = "valkey"
  access_string = "on ~* &* +@all" # 전용 pub/sub 캐시 — 필요 시 +@pubsub +@connection 으로 축소 가능

  authentication_mode {
    type = "iam"
  }
}

# Valkey RBAC: 유저는 password/IAM 인증만 가능(no-password-required 불가)하고,
# Valkey 그룹은 default 유저가 필요 없다(그룹 연결 시 default 요건이 자동 비활성). → app 유저만 등록.
resource "aws_elasticache_user_group" "this" {
  user_group_id = "${var.name}-chat"
  engine        = "valkey"
  user_ids      = [aws_elasticache_user.app.user_id]
}

# ───────── Valkey 단일 노드 (TLS + AUTH) ─────────
# 단일 노드: Pub/Sub 는 비영속이고 끊겨도 백필(DocumentDB)로 복구되므로 가용성 저하만 감수.
# 메시지 원본이 아니라 버스라 데이터 유실 리스크 없음(OpenSearch 단일 노드와 다름).
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name}-redis"
  description          = "Chat realtime fan-out (Pub/Sub), TLS + AUTH"

  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  user_group_ids             = [aws_elasticache_user_group.this.user_group_id]

  # Pub/Sub 버스라 스냅샷 불필요(메시지 원본은 DocumentDB).
  snapshot_retention_limit = 0

  apply_immediately = false

  tags = { Name = "${var.name}-redis" }
}

# ───────── 앱(EC2) 에 elasticache:Connect 권한 (IAM 인증, 최소권한) ─────────
# 앱 역할이 이 캐시의 이 user 로만 접속하도록 스코프. 장기 비번 없음.
resource "aws_iam_role_policy" "app_connect" {
  count = var.app_role_name != null ? 1 : 0
  name  = "${var.name}-redis-connect"
  role  = var.app_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["elasticache:Connect"]
      Resource = [
        aws_elasticache_replication_group.this.arn,
        aws_elasticache_user.app.arn
      ]
    }]
  })
}

# 앱이 부팅 시 읽을 Redis 프라이머리 엔드포인트. 생성 후에나 알 수 있어 SSM Parameter 로 publish 한다
# (ec2 모듈이 이 모듈의 app_sg_id·app_role_name 을 참조하므로, 반대로 output 을 직접 넘기면 순환 의존 →
#  media_cdn / monitoring_host 와 동일하게 이름 기반 SSM 조회로 회피). user_name·cache_name 은 결정적이라 prod 에서 직접 전달.
resource "aws_ssm_parameter" "endpoint" {
  name  = "/${var.name}/redis/endpoint"
  type  = "String"
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}
