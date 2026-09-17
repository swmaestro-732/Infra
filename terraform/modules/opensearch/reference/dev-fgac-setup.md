# dev OpenSearch FGAC 수동 설정 (인덱스 네임스페이스 격리)

dev 환경은 **새 OpenSearch 도메인을 만들지 않고** prod 도메인(`chilsami-search`)을 그대로 쓰되,
인덱스를 `dev-*` 네임스페이스로 격리한다. 접속 엔드포인트는 prod 와 동일하고 **자격증명만 dev 전용**이다.

- 앱 env: `OPENSEARCH_INDEX_PREFIX = "dev-"` (dev-server 모듈이 항상 주입)
- dev 인덱스: `dev-place_v1`, `dev-course_v1` (+ alias `dev-place`, `dev-course`)
- dev FGAC 역할/유저는 **Terraform 관리 대상이 아니다**(레포는 opensearch/elasticsearch provider 미사용).
  아래 `_security` REST API 절차로 **수동 생성**하고, 자격증명만 `chilsami/dev/opensearch` 시크릿에 주입한다.

> ⚠️ 비밀번호는 tfstate 에 넣지 않는다. `aws_secretsmanager_secret.dev_opensearch` 는 값 없이(fail-closed)
> 리소스만 Terraform 이 만들고, 값은 이 문서의 마지막 단계에서 out-of-band 로 주입한다.

---

## 0. 사전 — 마스터 자격증명 + SSM 터널

FGAC API 는 마스터 유저(`admin`, `chilsami/opensearch/master`)로만 호출한다.
도메인은 VPC 프라이빗이라 앱 EC2 를 점프 호스트로 한 SSM 포트포워딩이 유일한 경로다
(방식은 `chilsami-datastore-access` 스킬과 동일).

```bash
REGION=ap-northeast-2
APP_EC2=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=chilsami-app" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

OS_HOST=vpc-chilsami-search-n6rlfsvqijzno7g4fkecbjq4j4.ap-northeast-2.es.amazonaws.com

# 로컬 9200 → 앱EC2 → OpenSearch:443
aws ssm start-session --target "$APP_EC2" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters host="$OS_HOST",portNumber="443",localPortNumber="9200" \
  --region "$REGION"
# 다른 터미널에서 계속. "Waiting for connections..." 뜨면 준비 완료.

# 마스터 자격증명 로드
S=$(aws secretsmanager get-secret-value --secret-id chilsami/opensearch/master \
  --region "$REGION" --query SecretString --output text)
ADMIN_USER=$(echo "$S" | jq -r .username)
ADMIN_PASS=$(echo "$S" | jq -r .password)
```

이하 curl 은 모두 터널을 통해 `https://localhost:9200` 로 마스터 인증(`-k`: 호스트 불일치 무시)한다.

---

## 1. 역할 `dev-app-role` — dev-* 인덱스에만 권한 (prod 인덱스 격리)

```bash
curl -sk -u "$ADMIN_USER:$ADMIN_PASS" -XPUT \
  "https://localhost:9200/_plugins/_security/api/roles/dev-app-role" \
  -H 'Content-Type: application/json' -d '{
    "cluster_permissions": [
      "cluster:monitor/health",
      "cluster:monitor/main",
      "cluster_composite_ops"
    ],
    "index_permissions": [
      {
        "index_patterns": ["dev-*"],
        "allowed_actions": [
          "read",
          "write",
          "create_index",
          "manage_aliases",
          "indices:admin/mapping/put"
        ]
      }
    ]
  }'
```

`index_patterns` 이 `dev-*` 뿐이라 prod 인덱스(`place*`/`course*`)에는 권한이 없다(격리 경계).

## 2. 내부 유저 `dev-app` (비번 out-of-band)

```bash
DEV_OS_PASS='<out-of-band 로 강하게 생성한 비밀번호>'   # 히스토리/tfstate 에 남기지 말 것

curl -sk -u "$ADMIN_USER:$ADMIN_PASS" -XPUT \
  "https://localhost:9200/_plugins/_security/api/internalusers/dev-app" \
  -H 'Content-Type: application/json' -d "{
    \"password\": \"$DEV_OS_PASS\",
    \"backend_roles\": []
  }"
```

## 3. role_mapping — dev-app-role ← dev-app

```bash
curl -sk -u "$ADMIN_USER:$ADMIN_PASS" -XPUT \
  "https://localhost:9200/_plugins/_security/api/rolesmapping/dev-app-role" \
  -H 'Content-Type: application/json' -d '{
    "users": ["dev-app"]
  }'
```

## 4. dev 시크릿 값 주입 (`chilsami/dev/opensearch`)

Terraform 이 만든 빈 시크릿에 endpoint/username/password 를 주입한다.
`endpoint` 는 prod 도메인 VPC 엔드포인트와 동일하다.

```bash
aws secretsmanager put-secret-value --secret-id chilsami/dev/opensearch \
  --region "$REGION" \
  --secret-string "{
    \"endpoint\": \"$OS_HOST\",
    \"username\": \"dev-app\",
    \"password\": \"$DEV_OS_PASS\"
  }"
```

주입 후 dev 인스턴스가 교체(또는 CD 재배포)되면 dev-server 가 이 값을 fetch 해
`OPENSEARCH_ENDPOINT/USERNAME/PASSWORD` + `OPENSEARCH_INDEX_PREFIX=dev-` 로 앱에 주입한다.

## 5. (선택) dev 인덱스/alias 초기 생성

앱이 부팅 시 만들지 않는다면 수동으로:

```bash
DEV_OS_PASS='<위와 동일>'
for idx in dev-place_v1 dev-course_v1; do
  curl -sk -u "dev-app:$DEV_OS_PASS" -XPUT "https://localhost:9200/$idx"
done
curl -sk -u "dev-app:$DEV_OS_PASS" -XPOST "https://localhost:9200/_aliases" \
  -H 'Content-Type: application/json' -d '{
    "actions": [
      {"add": {"index": "dev-place_v1",  "alias": "dev-place"}},
      {"add": {"index": "dev-course_v1", "alias": "dev-course"}}
    ]
  }'
```

---

## 6. 격리 검증 — dev 자격증명으로 prod 인덱스 접근 시 403

dev-app 은 `dev-*` 밖으로 나갈 수 없어야 한다. 아래는 **403 이어야 정상**이다.

```bash
# prod 인덱스 읽기 시도 → 403 (Forbidden) 기대
curl -sk -o /dev/null -w '%{http_code}\n' -u "dev-app:$DEV_OS_PASS" \
  "https://localhost:9200/place_v1/_search"
# → 403

curl -sk -o /dev/null -w '%{http_code}\n' -u "dev-app:$DEV_OS_PASS" \
  "https://localhost:9200/course_v1/_search"
# → 403

# dev 인덱스는 접근 가능해야 정상 → 200
curl -sk -o /dev/null -w '%{http_code}\n' -u "dev-app:$DEV_OS_PASS" \
  "https://localhost:9200/dev-place/_search"
# → 200
```

403 이 아니라 200/404 가 나오면 역할의 `index_patterns` 가 넓거나 role_mapping 이 잘못된 것 —
1~3 단계를 재점검한다.
