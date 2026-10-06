# OpenSearch dev FGAC 프로비저닝

`provision-dev-fgac.sh` — dev 앱이 공유 OpenSearch 도메인에 붙을 때 쓰는 **데이터플레인 FGAC 객체**
(내부유저/롤/롤매핑)를 1회성으로 만든다. (SCRUM-567)

## 왜 Terraform 이 아니라 스크립트인가

- FGAC 내부유저/롤은 AWS provider 가 관리하는 도메인 config 가 **아니다**. 도메인 안에서 도는
  보안플러그인의 데이터플레인 객체라 `_plugins/_security` REST API 로만 만들어진다.
- 그 REST 엔드포인트는 **VPC 내부 전용**(퍼블릭 엔드포인트 없음)이라 CI 러너(VPC 밖)는 못 닿는다.
  관리하려면 어차피 **SSM 터널로 들어가 수동 실행**해야 한다.
- Terraform `opensearch` provider 로도 가능하지만(별도 루트/state/lock + 터널 apply), 거의 바뀌지
  않는 리소스 하나 때문에 상태관리 배선을 늘리는 값이 안 된다고 판단해 **멱등 스크립트**로 둔다.
  결과물(도메인에 생기는 유저/롤)은 어느 쪽이든 동일하다.

prod 앱은 master(admin) 유저로 붙어 별도 FGAC 가 필요없다 — 이 스크립트는 dev 전용이다.

## 실행

```bash
aws sso login --profile chilsami        # master + dev 시크릿 read 권한 필요(최소권한 infra 로는 불가)
AWS_PROFILE=chilsami ./scripts/opensearch/provision-dev-fgac.sh
```

스크립트가 알아서: 두 시크릿 로드 → SSM 터널(localhost:9243) 오픈 → 롤/유저/롤매핑 PUT →
dev 자격증명으로 인증 검증 → 터널 정리. 끝나면 **dev 앱을 1회 재기동**하면 `dev-*` 인덱스가
생성/색인되고 검색이 복구된다.

환경변수로 조정 가능: `AWS_REGION`(기본 ap-northeast-2), `LOCAL_PORT`(기본 9243),
`JUMP_NAME_TAG`(점프 호스트 Name 태그, 기본 chilsami-app).

## 멱등 / 재실행 (drift 대응)

모두 PUT 이라 **다시 돌려도 안전**하다. 상태파일이 없어 Terraform 식 drift 에러는 발생하지 않는다.
설정이 어긋날 수 있는 유일한 경우는:

- **dev 시크릿 회전**(`random_password.dev_opensearch`): 유저 비번이 어긋나 앱이 다시 401 →
  이 스크립트를 **다시 실행**하면 비번이 재동기화된다.
- 도메인 재생성/대시보드 수동 변경: 마찬가지로 재실행하면 원하는 상태로 복구된다.

## 생성되는 것

- 롤 `dev_app`: `dev-*` 인덱스 `indices_all` + 클러스터 `cluster_composite_ops`/`cluster_monitor`.
  prod 인덱스(`course_v1`/`place_v1`)는 접근 불가 → 격리 보장.
- 내부유저: dev 시크릿의 username/password.
- 롤매핑 `dev_app` → 그 유저.
