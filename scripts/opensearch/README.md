# OpenSearch dev FGAC 프로비저닝 (IAM/SigV4)

`provision-dev-fgac.sh` — dev 앱이 공유 OpenSearch 도메인에 붙을 때 쓰는 **데이터플레인 FGAC 객체**
(롤 + 롤매핑)를 1회성으로 만든다. 인증은 **IAM/SigV4**: dev 앱이 자기 EC2 인스턴스 역할로 요청에
서명하고, 도메인은 그 역할 ARN 을 backend_role 로 보고 권한을 부여한다. **비밀번호 없음.** (SCRUM-567)

## 왜 스크립트(수동)인가

- FGAC 롤/롤매핑은 AWS provider 가 관리하는 도메인 config 가 **아니다**. 도메인 보안플러그인의
  데이터플레인 객체라 `_plugins/_security` REST 로만 만들어진다.
- 그 엔드포인트는 **VPC 내부 전용**이라 CI 러너(VPC 밖)는 못 닿는다 → 터널로 수동 실행.
- Terraform `opensearch` provider 로도 가능하지만 별도 state/lock + 터널 apply 배선이 거의 안 바뀌는
  리소스엔 과해, 멱등 스크립트로 둔다.

prod 앱은 master 유저로 붙어 별도 FGAC 가 필요없다 — 이 스크립트는 dev 전용이다.

## 실행

```bash
aws sso login --profile chilsami        # master 시크릿 read + iam get-role 권한 필요
AWS_PROFILE=chilsami ./scripts/opensearch/provision-dev-fgac.sh
```

스크립트가: master 자격증명 + dev 역할 ARN 로드 → SSM 터널(localhost:9243) → 롤/롤매핑 PUT →
롤·backend_role 매핑 검증 → 터널 정리. 끝나면 **dev 앱을 1회 재기동**하면 인스턴스 역할 SigV4 로
인증되어 `dev-*` 인덱스가 생성/색인되고 검색이 복구된다.

환경변수: `AWS_REGION`(기본 ap-northeast-2), `LOCAL_PORT`(기본 9243),
`JUMP_NAME_TAG`(점프 호스트, 기본 chilsami-app), `DEV_ROLE_NAME`(기본 chilsami-dev-ec2-role).

## 멱등 / 재실행 (drift)

모두 PUT 이라 다시 돌려도 안전하다. 상태파일이 없어 Terraform 식 drift 에러는 없다. **비밀번호가
없어 회전도 없으므로 사실상 한 번 실행하면 끝**이다. 도메인을 재생성하거나 대시보드에서 롤을 수동
변경한 경우에만 재실행하면 원하는 상태로 복구된다.

## 전제 (앱/인프라 쪽)

- Backend 가 `OPENSEARCH_AUTH_MODE=iam` 를 지원해야 한다(SigV4 transport). → BackEnd PR(SCRUM-567).
- dev-server 가 `OPENSEARCH_ENDPOINT` + `OPENSEARCH_AUTH_MODE=iam` + `OPENSEARCH_REGION` 를 주입해야 한다
  (username/password 주입 안 함). → 이 레포 environments/dev + modules/dev-server.
- 도메인 접근정책이 같은 계정 IAM principal 을 허용해야 한다(현재 `AWS=*`, 인가는 FGAC 위임 → OK).

## 생성되는 것

- 롤 `dev_app`: `dev-*` 인덱스 `indices_all` + 클러스터 `cluster_composite_ops`/`cluster_monitor`.
  prod 인덱스(`course_v1`/`place_v1`)는 접근 불가 → 격리 보장.
- 롤매핑 `dev_app`.backend_roles = `[arn:aws:iam::<acct>:role/chilsami-dev-ec2-role]`.

## 클러스터 재생성 후 복구 — `recover-opensearch.sh` (SCRUM-675)

`chilsami-search` 는 단일 노드 시절 노드가 교체되며 클러스터가 빈 상태로 다시 만들어졌다(2026-10-20, 21).
지금은 2노드(2AZ)라 한 대가 교체돼도 복제본이 남는다. 두 대가 함께 사라지는 등 그래도 유실됐을 때,
Grafana "OpenSearch 검색 문서 수 급감" 알림이 오면 실행한다. 데이터 원본은 DB 라 유실은 없다.

```bash
aws sso login --profile chilsami
AWS_PROFILE=chilsami ./scripts/opensearch/recover-opensearch.sh
```

| 단계 | 하는 일 |
|---|---|
| 1. 마스터 로그인 확인 | prod 인스턴스 안에서 시크릿 자격증명으로 `authinfo` 호출. 401 이면 비밀번호를 임시 값으로 바꿨다가 시크릿 값으로 되돌린다(같은 값은 "변경 없음"으로 무시되기 때문). 200 이면 건너뛴다 |
| 2. dev 권한 | `provision-dev-fgac.sh` 로 `dev_app` 롤과 매핑을 다시 만든다 |
| 3. 앱 재시작 | prod 인스턴스를 한 대씩 `docker restart app` 하고 헬스 200 을 기다린 뒤 dev 도 재시작. 앱이 기동하며 인덱스를 만들고 빈 인덱스를 DB 에서 재색인한다 |
| 4. 확인 | 문서 수가 `MIN_DOCS`(기본 1000) 이상이 될 때까지 기다리고 인덱스별 문서 수를 출력한다 |

정상 상태에서 실행해도 1단계를 건너뛰고 재시작만 하므로 안전하다.
