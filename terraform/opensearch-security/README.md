# opensearch-security (dev FGAC)

dev 앱이 공유 OpenSearch 도메인에 붙을 때 쓰는 **데이터플레인 FGAC 객체**(내부유저/롤/롤매핑)를
Terraform `opensearch` provider 로 관리한다. AWS provider 는 도메인의 master 유저 하나만 관리할 뿐
그 외 내부 유저/롤은 못 만들기 때문에 이 설정이 따로 존재한다(배경은 `main.tf` 주석, SCRUM-567).

## 왜 CI 가 아니라 수동 apply 인가

도메인은 **VPC 내부 전용**(퍼블릭 엔드포인트 없음)이다. provider 는 도메인의
`_plugins/_security` REST API 에 직접 붙어야 하는데 CI 러너는 VPC 밖이라 닿지 못한다.
그래서 이 디렉토리는 `environments/` **밖**에 둬서 CI(plan/apply, prod/dev 매트릭스)에서 제외되고,
운영자가 **SSM 포트포워딩 터널**로 1회성 apply 한다.

## 선행 조건

- 도메인 보안 API 에 붙을 **master(admin)** 자격증명과 dev 자격증명 시크릿 2개를 읽을 수 있는 AWS 자격증명.
  (`chilsami` 관리자 프로파일. 최소권한 `chilsami-infra` 는 dev 시크릿 read 권한이 없다.)
- 점프 호스트로 쓸 running EC2(앱/모니터링 등 도메인 443 에 닿는 인스턴스).

## apply 절차

```bash
# 0) 관리자 자격증명
aws sso login --profile chilsami
export AWS_PROFILE=chilsami AWS_REGION=ap-northeast-2

# 1) 도메인 엔드포인트 + 점프 호스트 확인
OS_ENDPOINT=$(terraform -chdir=../environments/prod output -raw opensearch_endpoint)   # 또는 콘솔에서 확인
JUMP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=chilsami-app" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# 2) 터널 열기 (로컬 9243 → 도메인 443). 세션을 열어둔 다른 터미널에서:
aws ssm start-session --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$OS_ENDPOINT\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"9243\"]}"

# 3) init / plan / apply (기본 변수: url=https://localhost:9243, insecure=true)
terraform init
terraform plan
terraform apply
```

apply 후 dev 앱을 재기동하면(배포 1회) dev 유저로 인증이 되어 `dev-*` 인덱스가 생성/색인된다.

## 회전(rotation)

dev 시크릿(`random_password.dev_opensearch`)을 회전하면 내부 유저 비번이 어긋난다.
회전 후 이 설정을 **같은 터널 절차로 재-apply** 해 `opensearch_user.dev` 비번을 다시 동기화한다.
