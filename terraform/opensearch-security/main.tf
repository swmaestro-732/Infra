# ─────────────────────────────────────────────────────────────────────────────
# dev 앱의 OpenSearch FGAC 객체(내부유저/롤/롤매핑).
#
# 배경: dev 는 새 도메인을 만들지 않고 prod OpenSearch 도메인을 인덱스 네임스페이스(dev-*)로
#   격리 공유한다(SCRUM-538). environments/dev 가 dev 전용 자격증명 시크릿(chilsami/dev/opensearch)
#   과 OPENSEARCH_INDEX_PREFIX=dev- 를 앱에 주입하지만, 그 자격증명에 해당하는 "도메인 내부 유저/롤"
#   은 자동 생성되지 않았다 — FGAC 객체는 AWS provider 가 관리하는 도메인 config 가 아니라
#   도메인 보안플러그인의 데이터플레인 객체라 _plugins/_security REST 로만 만들어지기 때문.
#   그 결과 dev 앱이 존재하지 않는 유저로 인증 → 401 → dev-* 인덱스 미생성 → 검색 빈 결과였다(SCRUM-567).
#
# 이 설정이 그 누락분을 코드로 채운다. prod 앱은 master(admin) 유저로 붙어 별도 FGAC 가 필요없다.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_secretsmanager_secret_version" "master" {
  secret_id = "chilsami/opensearch/master"
}

data "aws_secretsmanager_secret_version" "dev" {
  secret_id = "chilsami/dev/opensearch"
}

locals {
  master = jsondecode(data.aws_secretsmanager_secret_version.master.secret_string)
  dev    = jsondecode(data.aws_secretsmanager_secret_version.dev.secret_string)
}

# dev 앱 전용 롤 — dev-* 인덱스에만 전체 권한(prod course_v1/place_v1 등은 접근 불가 → 격리 보장).
# 클러스터 권한은 앱이 쓰는 복합 연산(_bulk/_mget/_msearch)과 헬스/스탯 모니터로 한정.
resource "opensearch_role" "dev" {
  role_name   = "dev_app"
  description = "dev app - dev-* 인덱스 격리 접근 (SCRUM-567)"

  cluster_permissions = ["cluster_composite_ops", "cluster_monitor"]

  index_permissions {
    index_patterns  = ["dev-*"]
    allowed_actions = ["indices_all"]
  }
}

# 내부 유저 — username/password 는 앱이 읽는 dev 시크릿과 반드시 일치해야 한다(그 값 그대로 사용).
# 시크릿이 회전하면(random_password.dev_opensearch) 이 설정을 재-apply 해 유저 비번을 동기화한다.
resource "opensearch_user" "dev" {
  username = local.dev.username
  password = local.dev.password
}

resource "opensearch_roles_mapping" "dev" {
  role_name   = opensearch_role.dev.role_name
  description = "dev_app 롤 → dev 내부 유저 (SCRUM-567)"
  users       = [opensearch_user.dev.username]
}
