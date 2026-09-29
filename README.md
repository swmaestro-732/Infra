# 칠삼이 Infra

AWS와 Terraform으로 관리하는 **칠삼이(SOMA 732)** 백엔드 인프라 저장소입니다.
모든 클라우드 리소스를 코드(IaC)로 다루고, 변경은 PR에서 CI(plan)를 돌린 뒤 머지하고 Apply하는 흐름을 따릅니다.

> 현재 상태(2026-09): prod와 dev 두 환경이 배포돼 있습니다. prod에는 CDN, 검색(OpenSearch), 미디어(S3/CloudFront), 이벤트 큐(SQS), 관측(LGTM)까지 올라가 있고, dev는 prod 자원을 공유하면서 자체 서버와 로컬 DB로 격리해 돌립니다.

---

## 1. 아키텍처 (현재 배포됨)

```text
사용자 ──HTTPS──▶ Route53(courmy.com) ──▶ CloudFront(앱 CDN) ──▶ ALB(443) ──▶ EC2 ASG (Docker/Spring, private)
                                                                              ├──▶ RDS Writer, Reader
                                                                              ├──▶ OpenSearch (검색, FGAC, 한글 nori)
                                                                              ├──▶ SQS (fallback 이벤트 큐 + DLQ)
                                                                              ├──▶ S3 media (presigned 업로드) + CloudFront(media CDN)
                                                                              └──▶ Monitoring EC2 (LGTM + YACE, Grafana에서 Slack 알림)

dev.courmy.com ──▶ (같은 prod ALB에 host 규칙) ──▶ dev EC2 (Docker 앱 + Docker Postgres, 전용 EBS)
                                                    └──▶ prod OpenSearch 도메인 공유 (dev-* 인덱스로 격리)
```

- 리전: `ap-northeast-2`(서울), 단일 AWS 계정
- 상태 관리: S3 원격 백엔드에 S3 네이티브 잠금(`use_lockfile`)
- 배포: GitHub Actions와 AWS OIDC(키리스 인증), `prod` 환경은 수동 승인
- 설정값 주입: 앱이 부팅할 때 Secrets Manager(DB, app config, OpenSearch, JWT)와 SSM Parameter(미디어 CDN 주소, 모니터링 호스트 IP)를 읽어 옵니다. 모듈 사이 순환 의존을 피하려고 output 직접 참조 대신 이름으로 넘겨 런타임에 조회합니다.
- 단계별 목표 아키텍처(EKS까지)는 draw.io 다이어그램을 참고하세요: <https://app.diagrams.net/#G12j-b7BLnVoiHwl72Zg7ODgCAtHVN1gsX>
  (마지막 "현재 상황" 페이지가 지금 실배포 상태이고, 앞의 1~7단계는 계획입니다. 원본은 팀 드라이브 `SOMA 칠삼이/칠삼이_시스템 아키텍처.drawio`)

### 1-1. dev 환경

dev는 `environments/dev`로 상태를 분리한 독립 루트입니다. 비용과 운영 부담을 줄이려고 prod 자원을 최대한 공유합니다.

- 공개는 `dev.courmy.com` 하나로만 합니다. dev 전용 ALB를 새로 만들지 않고, prod ALB의 443 리스너에 host 규칙을 얹어 dev 타깃그룹으로 보냅니다.
- 서버는 ASG 없이 단일 EC2입니다. 앱 컨테이너와 Postgres(postgis) 컨테이너를 한 인스턴스에서 돌리고, DB 데이터는 전용 EBS에 담아 인스턴스가 교체돼도 보존합니다.
- prod의 VPC, 프라이빗 라우트테이블(NAT), Route53 존, ACM 인증서, app config 시크릿, 미디어 버킷을 prod 상태(remote_state)로 읽어 공유합니다. dev는 prod 상태를 읽기만 하고 바꾸지 않습니다.
- 검색은 prod OpenSearch 도메인을 함께 쓰되 인덱스를 `dev-*` 접두어로 갈라 격리합니다.
- develop 브랜치에 푸시하면 SSM send-command로 재배포합니다(prod의 ASG instance refresh와는 다른 방식).

### 1-2. 로드맵 (이후 방향)

목표는 EKS 기반 플랫폼으로 단계적으로 확장하는 것입니다. 아래는 방향 요약이고, 구체 작업은 Jira(`SCRUM`)와 PR로 추적합니다. 단계별 상세 설계는 LLM 위키 `.ai/infra/roadmap.md`에 있습니다.

| 단계 | 내용 | 상태 |
|------|------|------|
| 1 | MVP (ALB, EC2 ASG, RDS Writer/Reader, CloudFront, ECR, OIDC) | 배포됨 |
| 2 | 관측 (자체호스팅 LGTM = Grafana/Loki/Tempo/Mimir/Prometheus, Slack 알림) | 배포됨 |
| 3 | 미디어, 검색, 이벤트 (S3/CloudFront 미디어, OpenSearch, SQS fallback 큐) | 배포됨, ElastiCache(Redis)와 MSK(Kafka)는 예정 |
| 4 | EKS 전환과 HA (HPA/Karpenter, WAF, IRSA) | 예정 |
| 5 | GitOps와 시크릿 (ArgoCD, External Secrets, Packer, VPC 엔드포인트) | 예정 |
| 6 | 보안과 알림 (CloudTrail, EventBridge, SNS/Lambda) | 예정 |
| 7 | 신뢰성 하드닝 (GuardDuty, Security Hub, Config, Flow Logs, NAT 이중화, Backup) | 예정 |

---

## 2. 디렉터리 구조

```text
Infra/
├── .github/
│   ├── workflows/
│   │   ├── terraform-ci.yml       # PR: 변경 환경 감지, fmt/validate/tflint, Trivy, plan+비용
│   │   └── terraform-apply.yml    # main 머지: prod 먼저 apply 후 dev (Environment 보호)
│   └── pull_request_template.md
├── terraform/
│   ├── environments/
│   │   ├── prod/                  # prod 루트 (단일 계정 기준값)
│   │   └── dev/                   # dev 루트 (독립 상태, prod 자원 공유)
│   └── modules/                   # 재사용 모듈
└── README.md
```

- environments/: 실제 `terraform` 명령을 실행하는 루트입니다. prod와 dev를 각각 독립 상태로 둡니다. dev는 prod 상태를 remote_state로 읽어 공유 자원을 참조합니다.
- modules/: 재사용 단위 12개입니다. network, alb, ec2, rds, cloudfront, ecr, opensearch, monitoring, media, sqs, iam, dev-server.

---

## 3. 사전 요구사항

| 도구 | 버전 | 비고 |
|------|------|------|
| Terraform | `>= 1.11.0` | `tfenv` 권장 |
| AWS CLI | v2 | 로컬 plan 시 자격증명 필요 |
| gh CLI | 최신 | (선택) PR 작업 |

---

## 4. 로컬 개발 흐름

```bash
# prod 예시 (dev는 environments/dev 에서 동일)
cd terraform/environments/prod

# 1) 백엔드 없이 검증만 (자격증명 불필요)
terraform fmt -recursive
terraform init -backend=false
terraform validate

# 2) 실제 plan (AWS 자격증명 + 상태 버킷 필요)
terraform init
terraform plan
```

> `*.tfstate`는 `.gitignore` 처리돼 있습니다. 절대 커밋하지 마세요.

---

## 5. 원격 상태 부트스트랩 (최초 1회)

`backend.tf`가 가리키는 S3 버킷을 첫 `terraform init` 전에 먼저 만들어야 합니다.

```bash
aws s3api create-bucket \
  --bucket chilsami-tfstate-ap-northeast-2 \
  --region ap-northeast-2 \
  --create-bucket-configuration LocationConstraint=ap-northeast-2

# 버전 관리 활성화 (상태 복구용)
aws s3api put-bucket-versioning \
  --bucket chilsami-tfstate-ap-northeast-2 \
  --versioning-configuration Status=Enabled
```

> 상태 잠금은 DynamoDB 대신 S3 네이티브 잠금(`use_lockfile = true`)을 씁니다. 별도 락 테이블이 필요 없습니다.
> prod와 dev는 같은 버킷 안에서 상태 키(`prod/terraform.tfstate`, `dev/terraform.tfstate`)로 분리합니다.

---

## 6. CI/CD

| 워크플로우 | 트리거 | 하는 일 |
|------------|--------|---------|
| `terraform-ci.yml` | `terraform/**` 변경 PR | 변경 환경 감지, fmt/validate/tflint, Trivy 보안 스캔, `plan`과 비용 PR 코멘트 |
| `terraform-apply.yml` | `main` 푸시 또는 수동 | Trivy 게이트 통과 후 prod 먼저 apply, 그다음 dev (Environment 보호) |

- 인증: 장기 액세스 키 대신 AWS OIDC를 씁니다. 레포 변수 `AWS_ROLE_ARN`이 있어야 plan, apply, 비용 잡이 돕니다.
- 한 PR은 한 환경만: 한 PR이 prod와 dev를 동시에 바꾸지 못하게 CI가 막습니다. plan과 비용은 변경된 환경에 대해 돌립니다.
- 보안 스캔(Trivy): IaC 미스컨피그를 검사해 SARIF로 Code Scanning(Security 탭)과 PR 인라인에 표시하고 Job Summary에 요약합니다. `CRITICAL`만 머지를 막고, `HIGH`와 `MEDIUM`은 표시만 합니다.
- plan 가독성: `terraform plan` 결과를 PR에 접히는 코멘트로 갱신(푸시마다 upsert)하고 Job Summary에도 남깁니다.
- 비용 추정: Infracost로 월 예상 비용을 PR 코멘트에 표시합니다. 무료 API 키 `INFRACOST_API_KEY`가 없으면 비용 잡은 건너뜁니다.
- apply 보호: apply는 `CRITICAL` 게이트를 지난 뒤 GitHub `prod` Environment의 수동 승인을 거쳐 실행합니다. dev는 prod apply가 성공한 뒤 이어서 적용합니다.

---

## 7. 컨벤션

### 7-1. 브랜치 전략 (트렁크 기반)

- `main`: 항상 배포 가능한 보호 브랜치입니다. 직접 푸시를 막고 PR로만 병합합니다. Infra는 `develop` 없이 `feat`에서 `main`으로 갑니다.
- 작업 브랜치: `<type>/SCRUM-<번호>-<요약>` 형태입니다. 예를 들어 `feat/SCRUM-228-opensearch`, `fix/SCRUM-158-monitoring`.
- 작업은 Jira(`soma73.atlassian.net`, 키 `SCRUM`)로 추적하고 브랜치, 커밋, PR 제목에 키를 붙입니다.

### 7-2. 커밋 컨벤션 (Conventional Commits)

```text
<type>(<scope>): <제목>
```

- type: `feat`, `fix`, `refactor`, `ci`, `docs`, `chore`, `test`
- scope(선택): `network`, `alb`, `ec2`, `rds`, `cloudfront`, `ecr`, `opensearch`, `monitoring`, `media`, `sqs`, `iam`, `dev-server`, `state`
- 예: `feat(opensearch): Amazon OpenSearch 검색 도메인 모듈`

### 7-3. PR 규칙

- 제목: `SCRUM-<번호> <type>(<scope>): <내용>`
- PR 템플릿을 채우고 Terraform plan 결과(0 destroy 확인)를 반드시 첨부합니다.
- CI(fmt/validate/lint, Trivy, plan/cost)를 통과해야 합니다. main 보호 규칙상 PR이 필수이고, CodeRabbit 리뷰를 확인해 반영한 뒤 머지합니다(누락되면 `@coderabbitai review`).
- `Squash and merge`를 권장합니다.

### 7-4. Terraform 코드 컨벤션

- 파일 분리: `versions.tf`, `providers.tf`, `backend.tf`, `variables.tf`, `outputs.tf`, `main.tf`
- 리소스와 변수 이름은 `snake_case`로 쓰고, 리소스 이름에 타입을 겹쳐 쓰지 않습니다(`aws_lb.this`는 되고 `aws_lb.alb_lb`는 안 됨).
- 모든 변수는 `description`과 `type`을 명시하고, 출력은 `outputs.tf`에 모읍니다.
- 공통 태그(`Project`, `Environment`, `ManagedBy`)는 provider `default_tags`로 자동 부여합니다.
- 모듈 디렉터리 구조: `modules/<name>/{main.tf, variables.tf, outputs.tf, versions.tf}`
- 보안그룹은 network 모듈에 두지 않고 소비자 모듈이 직접 만들며, SG에서 SG를 참조하는 방식으로 연결합니다.
- 다른 모듈이 규칙을 덧붙이는 SG는 inline `ingress/egress` 대신 standalone `aws_security_group_rule`로 관리합니다(둘을 섞으면 perpetual diff와 apply 충돌이 납니다). 라이브 SG를 inline에서 standalone으로 바꿀 때는 남은 인라인 규칙을 먼저 revoke해야 `InvalidPermission.Duplicate` 없이 apply가 통과합니다.
- 앱 서비스 포트는 환경 루트의 `local.app_port` 하나로 묶어 ec2와 monitoring 모듈에 함께 넘깁니다. 두 모듈이 포트를 따로 보면 Prometheus 스크레이프가 막혀 오탐이 납니다.
- 커밋 전 `terraform fmt -recursive`는 필수입니다.

---

## 8. 시크릿과 환경 변수 (GitHub)

| 이름 | 종류 | 용도 |
|------|------|------|
| `AWS_ROLE_ARN` | Repository Variable | Actions가 OIDC로 assume 할 IAM Role ARN |
| `INFRACOST_API_KEY` | Repository Secret | 비용 추정(선택). 없으면 비용 잡을 건너뜀 |

> ARN은 민감정보가 아니라서 Secret이 아닌 Variable로 등록합니다. 장기 액세스 키는 쓰지 않습니다.

> 애플리케이션이 읽는 값(DB 자격증명, app config, OpenSearch, JWT)은 Secrets Manager에 두고, 값 자체는 코드로 만들지 않고 배포 후 콘솔이나 CLI로 주입합니다.
