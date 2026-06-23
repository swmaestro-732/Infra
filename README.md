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
│   │   └── dev/                   # 환경별 루트 모듈 (여기서 terraform 실행)
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

- **environments/**: 실제 `terraform` 명령을 실행하는 루트. 환경(dev/stg/prod)별로 분리.
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
cd terraform/environments/dev

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
| `terraform-ci.yml` | `terraform/**` 변경 PR | fmt · validate · tflint, OIDC 등록 시 `plan` |
| `terraform-apply.yml` | `main` 푸시 / 수동 | `dev` 환경에 `apply` (Environment 보호) |

- **인증**: 장기 액세스 키 대신 **AWS OIDC**. 레포 변수 `AWS_ROLE_ARN` 이 있어야 `plan`/`apply` 잡이 활성화됩니다.
- `apply` 잡은 GitHub `dev` Environment 를 사용하므로, 승인자를 지정해 **수동 승인 게이트**를 걸 수 있습니다.

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

---

## 9. 다음 작업 (MVP1 To-Do)

- [ ] `modules/network` — VPC / Subnet / IGW / NAT
- [ ] `modules/alb` — ALB + HTTPS 리스너 + 타깃 그룹
- [ ] `modules/ec2` — EC2 + Docker, ALB 타깃 등록
- [ ] `modules/rds` — Writer/Reader, Multi-AZ
- [ ] `environments/dev/main.tf` 에서 모듈 연결
