# DocumentDB IAM 인증 유저 프로비저닝 (SCRUM-688)

앱(EC2)이 **인스턴스 역할로 password-less 접속**(MONGODB-AWS)하려면, DocumentDB 클러스터의 `$external`
DB 에 "앱 역할 ARN = readWrite 유저" 를 1회 등록해야 한다. 이 등록은 AWS API 가 아니라 클러스터 내부
명령(`db.createUser`)이고, 클러스터는 **VPC 프라이빗**이라 CI/로컬에서 직접 못 닿는다 — **앱 EC2 를 점프
호스트로 한 SSM 터널** 경유로 master 로 접속해 실행한다. (OpenSearch FGAC 프로비저닝과 동일 패턴.)

> 왜 Terraform 이 아니라 스크립트인가: DocumentDB 유저는 TF 리소스가 없다(클러스터 내부 명령). 비번 없는
> IAM 유저라 회전도 없어 **사실상 1회성**이다. 역할/권한 변경·클러스터 재생성 시에만 재실행한다.

## 사전조건

- `aws sso login --profile chilsami` — master 시크릿 read + `iam get-role` 가능한 관리자 프로필.
- 로컬 설치: `mongosh`(MONGODB-AWS 지원 버전), `session-manager-plugin`, `curl`, `python3`.
  - `brew install mongosh` / `brew install --cask session-manager-plugin`

## 실행

```bash
AWS_PROFILE=chilsami ./provision-iam-user.sh
```

스크립트가 자동으로: master 시크릿·앱 역할 ARN 로드 → Amazon CA 번들 다운로드 → SSM 터널
(localhost:27017 → 클러스터, 점프 호스트 `chilsami-app`) → `$external` 에 유저 createUser/updateUser(멱등)
→ 등록 검증.

### 오버라이드 (환경변수)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `AWS_PROFILE` | `chilsami` | master 시크릿 read 권한 프로필 |
| `APP_ROLE_NAME` | `chilsami-ec2-role` | `$external` 유저로 등록할 앱 인스턴스 역할 |
| `DOCDB_DB` | `chat` | 앱이 readWrite 할 DB |
| `DOCDB_SECRET_ID` | `chilsami/docdb/credentials` | master 자격증명 시크릿 |
| `LOCAL_PORT` | `27017` | 로컬 터널 포트(27017 점유 시 변경) |
| `JUMP_NAME_TAG` | `chilsami-app` | 점프 호스트 인스턴스 Name 태그 |

## 보안 노트

- master 자격증명은 **argv(`ps` 노출)·환경변수(`/proc/<pid>/environ` 노출) 대신 0600 임시 JS 파일**로
  mongosh 에 전달하고(`--file`) 종료 시 삭제한다(OpenSearch provision 의 `curl -K` 와 동일 취지).
  같은 사용자/root 는 그 파일에도 접근 가능하나, 1회성 실행 + 관리자 로컬 권한 전제라 노출 범위는 제한적이다.
- TLS 유지: 인증서는 Amazon global CA 로 검증(`tlsCAFile`), 터널 특성상 호스트명만 불일치하므로
  `tlsAllowInvalidHostnames` 로 **호스트명 검증만** 생략한다(`--tlsInsecure`/검증 전체 생략 아님).
- 로컬 포트가 이미 점유돼 있으면 **거부**한다 — 다른 프로세스(예: 다른 DocumentDB 터널)의 리스너에 붙어
  의도치 않은 클러스터에 명령을 보내는 것을 막기 위함.
- 앱 EC2 인스턴스 역할에는 **master 시크릿 read 를 주지 않는다**(최소권한, SCRUM-686 CodeRabbit #4).
  이 스크립트는 그 권한이 있는 관리자가 자기 머신에서 실행한다.

## 이후 (SCRUM-688 Part 2/3)

- **Part 2 (Infra)**: ec2 user_data 가 `/chilsami/docdb/endpoint`(SSM)를 읽어 `DOCDB_ENDPOINT` env 주입
  (Redis 배선 #98 와 동일 패턴).
- **Part 3 (BackEnd)**: Mongo 드라이버 접속 —
  `mongodb://$DOCDB_ENDPOINT:27017/?tls=true&tlsCAFile=global-bundle.pem&retryWrites=false&authSource=$external&authMechanism=MONGODB-AWS`,
  메시지 스키마/인덱스 설계.

> Part 1(이 스크립트)·2·3 은 함께 끝나야 end-to-end 접속이 검증된다. BackEnd 연동 착수 시 같이 수행.
