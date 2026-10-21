# OpenSearch FGAC 프로비저닝 (dev 앱 + 사람용 admin)

`provision-dev-fgac.sh` — 클러스터 안 보안 인덱스에만 저장되는 **데이터플레인 FGAC 객체**를 만든다.
- dev 앱: 롤 `dev_app` + 롤매핑(dev EC2 역할 ARN → backend_role). dev 앱은 인스턴스 역할 SigV4 로 붙는다. (SCRUM-567)
- 사람: 내부 사용자 `admin`(시크릿 `chilsami/opensearch/master` 의 비밀번호) + `all_access`, `security_manager` 매핑.
  Dashboards 에 아이디/비밀번호로 로그인한다. (SCRUM-675)

FGAC 마스터는 prod 앱 IAM 역할(`chilsami-ec2-role`)이라 도메인 설정에 남는다. prod 앱은 이 스크립트 없이 붙는다.
스크립트는 SSO 관리자가 이 역할을 assume 한 임시 자격증명으로 `curl --aws-sigv4` 서명해 실행한다.

## 왜 스크립트(수동)인가

- FGAC 롤/롤매핑은 AWS provider 가 관리하는 도메인 config 가 **아니다**. 도메인 보안플러그인의
  데이터플레인 객체라 `_plugins/_security` REST 로만 만들어진다.
- 그 엔드포인트는 **VPC 내부 전용**이라 CI 러너(VPC 밖)는 못 닿는다 → 터널로 수동 실행.
- Terraform `opensearch` provider 로도 가능하지만 별도 state/lock + 터널 apply 배선이 거의 안 바뀌는
  리소스엔 과해, 멱등 스크립트로 둔다.

## 실행

```bash
aws sso login --profile chilsami        # chilsami-ec2-role assume + 시크릿 read + iam get-role 권한 필요
AWS_PROFILE=chilsami ./scripts/opensearch/provision-dev-fgac.sh
```

스크립트가: 마스터 역할 assume → SSM 터널(localhost:9243) → 마스터 인증 확인 → dev_app 롤/롤매핑 PUT →
admin 내부 사용자 PUT → all_access, security_manager 매핑에 admin 추가(기존 매핑 유지) → 터널 정리.
끝나면 **dev 앱을 1회 재기동**하면 `dev-*` 인덱스가 생성/색인된다.

환경변수: `AWS_REGION`(기본 ap-northeast-2), `LOCAL_PORT`(기본 9243),
`JUMP_NAME_TAG`(점프 호스트, 기본 chilsami-app), `DEV_ROLE_NAME`(기본 chilsami-dev-ec2-role).

## 멱등 / 재실행 (drift)

모두 PUT 이라 다시 돌려도 안전하다. 다음 경우에 다시 돌린다.
- 단일 노드 교체로 클러스터가 재생성됐을 때(보안 인덱스가 초기화돼 dev_app, admin 이 사라짐)
- 시크릿 admin 비밀번호를 회전했을 때(Terraform `random_password.master` keepers 변경 후 apply)

## 전제 (앱/인프라 쪽)

- Backend 가 `OPENSEARCH_AUTH_MODE=iam` 를 지원해야 한다(SigV4 transport). → BackEnd PR(SCRUM-567).
- dev-server 가 `OPENSEARCH_ENDPOINT` + `OPENSEARCH_AUTH_MODE=iam` + `OPENSEARCH_REGION` 를 주입해야 한다
  (username/password 주입 안 함). → 이 레포 environments/dev + modules/dev-server.
- 도메인 접근정책이 같은 계정 IAM principal 을 허용해야 한다(현재 `AWS=*`, 인가는 FGAC 위임 → OK).

## 생성되는 것

- 롤 `dev_app`: `dev-*` 인덱스 `indices_all` + 클러스터 `cluster_composite_ops`/`cluster_monitor`.
  prod 인덱스(`course_v1`/`place_v1`)는 접근 불가 → 격리 보장.
- 롤매핑 `dev_app`.backend_roles = `[arn:aws:iam::<acct>:role/chilsami-dev-ec2-role]`.
