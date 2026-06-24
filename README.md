# 칠삼이 Infra

AWS + Terraform 기반 **칠삼이(SOMA 732)** 백엔드 인프라 저장소입니다.
모든 클라우드 리소스는 코드(IaC)로 관리하며, 변경은 PR → CI(plan) → 머지 → Apply 흐름을 따릅니다.

> 🎯 현재 목표: **MVP1** — `ALB → EC2(Docker) → RDS(Writer/Reader, Multi-AZ)` 최소 구성을 Terraform으로 구축

---

## 1. 아키텍처 (MVP1)

```
Android ──HTTPS──▶ ALB ──▶ EC2 (Docker / Spring) ──▶ RDS Writer (Multi-AZ)
                  (Public)     (Private)                └─▶ RDS Reader (Read Replica)
```

- **리전**: `ap-northeast-2` (서울)
- **상태 관리**: S3 원격 백엔드 + S3 네이티브 잠금(`use_lockfile`)
- **배포**: GitHub Actions + AWS OIDC(키리스 인증)
- 전체 단계별 아키텍처 다이어그램은 팀 드라이브 `SOMA 칠삼이/칠삼이_시스템 아키텍처.drawio` 참고

---

## 2. 디렉터리 구조

```
Infra/
├── .github/
│   ├── workflows/
│   │   ├── terraform-ci.yml       # PR: fmt · validate · tflint · plan
│   │   └── terraform-apply.yml    # main 머지: apply (Environment 보호)
│   └── pull_request_template.md
├── terraform/
│   ├── environments/
│   │   └── prod/                  # 루트 모듈 (여기서 terraform 실행)
│   │       ├── backend.tf         # 원격 상태(S3)
│   │       ├── providers.tf       # AWS provider + 공통 태그
│   │       ├── versions.tf        # TF/provider 버전 제약
│   │       ├── main.tf            # 모듈 호출 (network/alb/ec2/rds)
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars.example
│   └── modules/                   # 재사용 모듈 (MVP1에서 추가)
└── README.md
```

- **environments/**: 실제 `terraform` 명령을 실행하는 루트. 단일 AWS 계정을 쓰므로 현재 환경은 `prod` 하나(상태 격리 + 향후 확장 대비 폴더 층 유지).
- **modules/**: `network`, `alb`, `ec2`, `rds` 같은 재사용 단위. 환경 루트에서 호출.

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
cd terraform/environments/prod

# 1) 변수 파일 준비
cp terraform.tfvars.example terraform.tfvars

# 2) 백엔드 없이 검증만 (자격증명 불필요)
terraform fmt -recursive
terraform init -backend=false
terraform validate

# 3) 실제 plan (AWS 자격증명 + 상태 버킷 필요)
terraform init
terraform plan
```

> 💡 `terraform.tfvars`, `*.tfstate` 는 `.gitignore` 처리되어 있습니다. **절대 커밋하지 마세요.**

---

## 5. 원격 상태 부트스트랩 (최초 1회)

`backend.tf` 가 가리키는 S3 버킷을 **첫 `terraform init` 전에** 먼저 만들어야 합니다.

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

> 상태 잠금은 DynamoDB 대신 S3 네이티브 잠금(`use_lockfile = true`)을 사용하므로 별도 락 테이블이 필요 없습니다.

---

## 6. CI/CD

| 워크플로우 | 트리거 | 하는 일 |
|------------|--------|---------|
| `terraform-ci.yml` | `terraform/**` 변경 PR | fmt·validate·tflint / **Trivy 보안 스캔** / `plan`+**비용** PR 코멘트 |
| `terraform-apply.yml` | `main` 푸시 / 수동 | **Trivy 게이트** → `prod` 환경 `apply` (Environment 보호) |

- **인증**: 장기 액세스 키 대신 **AWS OIDC**. 레포 변수 `AWS_ROLE_ARN` 이 있어야 `plan`/`apply`/비용 잡이 활성화됩니다.
- **보안 스캔 (Trivy)**: IaC 미스컨피그를 검사해 결과를 **SARIF로 Code Scanning(Security 탭) + PR 인라인**에 표시하고 **Job Summary**에 요약. 게이팅은 **`CRITICAL`만 차단**, `HIGH`/`MEDIUM`은 표시만.
- **plan 가독성**: `terraform plan` 결과를 PR에 **collapsible 코멘트**로 upsert(푸시마다 갱신) + Job Summary.
- **비용 추정**: **OpenInfraQuote**(OSS, API 키 불필요)로 월 예상 비용을 PR 코멘트로 표시.
- **apply 보호**: `apply`는 `CRITICAL` 게이트 통과 후 GitHub `prod` Environment 의 **수동 승인**을 거쳐 실행되며, 적용 결과는 Job Summary 에 기록됩니다.

---

## 7. 컨벤션

### 7-1. 브랜치 전략 (트렁크 기반)

- `main`: 항상 배포 가능한 보호 브랜치. 직접 푸시 금지, PR로만 병합.
- 작업 브랜치: `<type>/<요약>` — 예) `feat/alb-module`, `fix/rds-sg`, `ci/plan-comment`

### 7-2. 커밋 컨벤션 (Conventional Commits)

```
<type>(<scope>): <제목>
```

- **type**: `feat` `fix` `refactor` `ci` `docs` `chore` `test`
- **scope**(선택): `network` `alb` `ec2` `rds` `iam` `state` `repo` 등
- 예) `feat(rds): writer/reader 인스턴스 모듈 추가`

### 7-3. PR 규칙

- 제목은 커밋 컨벤션과 동일하게.
- PR 템플릿을 채우고 **plan 결과를 반드시 첨부**.
- CI(fmt/validate/lint) 통과 + 리뷰 1명 이상 승인 후 머지.
- `Squash and merge` 권장.

### 7-4. Terraform 코드 컨벤션

- 파일 분리: `versions.tf` / `providers.tf` / `backend.tf` / `variables.tf` / `outputs.tf` / `main.tf`
- 리소스·변수 이름은 `snake_case`, 리소스 이름에 타입 중복 금지 (`aws_lb.this` ○, `aws_lb.alb_lb` ✕)
- 모든 변수는 `description` + `type` 명시, 출력은 `outputs.tf` 에 모음.
- 공통 태그(`Project`/`Environment`/`ManagedBy`)는 provider `default_tags` 로 자동 부여.
- 모듈 디렉터리 구조: `modules/<name>/{main.tf, variables.tf, outputs.tf}`
- 커밋 전 `terraform fmt -recursive` 필수.

---

## 8. 시크릿 / 환경 변수 (GitHub)

| 이름 | 종류 | 용도 |
|------|------|------|
| `AWS_ROLE_ARN` | Repository **Variable** | Actions가 OIDC로 assume 할 IAM Role ARN |

> ARN은 민감정보가 아니므로 Secret 이 아닌 **Variable** 로 등록합니다. 장기 액세스 키는 사용하지 않습니다.

> 작업 항목(MVP1 모듈 등)은 README가 아니라 **GitHub Issues / PR** 로 추적합니다.
