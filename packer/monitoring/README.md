# 모니터링 골든 AMI (SCRUM-685)

AL2023 x86_64에 2GB swap, Docker, jq, Compose v2.29.7, AWS CLI v2와 모니터링 이미지 6개를 미리 설치한다. Docker는 부팅 시 자동 시작하며 swappiness=10은 재부팅 후에도 유지한다. 이미지 캐시와 swap을 위해 빌드 루트 볼륨은 운영 호스트와 같은 20GB gp3를 사용한다.

Terraform이 config의 SoT다. EBS `/data` 마운트, config 작성, S3·grafana.com 대시보드 다운로드, Secrets Manager → `.env`, `docker compose up -d`는 계속 런타임 user_data에서 수행한다. 시크릿·환경별 config·관측 데이터는 AMI에 넣지 않는다.

## 빌드

저장소 루트에서 실행한다. **`packer build`와 수동 CI 실행은 실제 EC2·AMI·스냅샷을 생성하고 비용이 발생한다.**

```bash
packer init packer/monitoring
packer fmt -check packer/monitoring
packer validate packer/monitoring
packer build packer/monitoring
```

기본값은 `region=ap-northeast-2`, 빌드 인스턴스 `instance_type=t3.small`, 빈 `vpc_id`/`subnet_id`다. 빈 네트워크 값은 Packer가 default VPC/subnet을 선택하게 한다. default VPC가 없거나 별도 네트워크를 쓰려면 같은 VPC의 퍼블릭 서브넷을 지정한다.

```bash
packer build \
  -var 'vpc_id=vpc-EXAMPLE' \
  -var 'subnet_id=subnet-EXAMPLE' \
  packer/monitoring
```

빌드 인스턴스에는 인터넷 경로(Internet Gateway)와 공인 IP가 필요하다. SSH는 빌드 실행자의 공인 IP에서만 임시 허용하고, dnf·Compose/AWS CLI 다운로드·컨테이너 레지스트리 접근이 가능해야 한다. 빌드용 계정/리전은 운영 Terraform과 동일하게 사용한다(`owners=["self"]`). AWS 자격증명은 로컬 프로필 또는 환경변수로 제공한다.

GitHub Actions의 **Packer Monitoring AMI**는 `workflow_dispatch`만 지원한다. 필요하면 `vpc_id`/`subnet_id` 입력을 지정한다. 기존 Terraform Apply와 같은 `prod` Environment 및 `${{ vars.AWS_ROLE_ARN }}`의 OIDC 인증을 사용한다. 해당 역할에는 Packer의 EC2 실행·종료, 임시 키페어/보안그룹 생성·삭제, AMI/스냅샷 생성·태깅 권한이 필요하다. 역할 정책과 VPC의 실제 접근 가능 여부는 첫 빌드 전에 확인한다. 이 변경은 IAM 정책을 추가하지 않는다.

## Cutover와 롤백

1. PR을 머지한다. `use_golden_ami=false`가 기본이므로 최신 AL2023와 기존 부팅 설치를 유지한다. 골든 AMI 조회는 `count=0`이라 첫 AMI가 없어도 이 조회 때문에 실패하지 않는다. false로 렌더링한 user_data는 기존과 동일하다.
2. 수동 Packer 빌드로 첫 `chilsami-monitoring-golden-<timestamp>` AMI를 생성하고 `available` 상태를 확인한다.
3. 별도 변경으로 `terraform/environments/prod/main.tf`의 `module "monitoring"`에 아래 한 줄을 추가하고 plan 검토 후 apply한다. 이번 변경에서는 prod 코드를 수정하지 않는다.

   ```hcl
   use_golden_ami = true
   ```

true일 때 같은 계정의 `available` AMI 중 `chilsami-monitoring-golden-*`에 맞는 최신 AMI를 선택한다. 부팅 시 swap/패키지/Compose/AWS CLI 설치를 생략하고 docker·aws·jq·Compose 존재 여부를 먼저 검사한다. 누락되면 EBS/config/시크릿 처리 전에 실패한다. 이후 런타임 작업은 false 경로와 같다.

모니터링은 ASG가 아닌 단독 EC2다. 토글 전환은 AMI와 user_data 변경으로 **인스턴스를 교체하므로 일시 중단이 발생한다.** 별도 데이터 EBS와 고정 ENI는 유지된다. 이후에도 새 골든 AMI를 빌드하면 다음 Terraform plan/apply에서 `most_recent`에 따라 교체가 제안될 수 있다.

롤백은 `use_golden_ami = false`로 바꾸거나 해당 줄을 제거하고 plan 검토 후 apply한다. 최신 AL2023 + 기존 설치 경로로 인스턴스를 다시 만든다. 이전 인스턴스나 특정 AMI로 돌아가는 방식은 아니다.

## 버전 동기화

`ansible/roles/monitoring/defaults/main.yml`의 `lgtm_images` 목록은 `terraform/modules/monitoring/templates/docker-compose.yml.tftpl`과 함께 갱신한다. Grafana는 `variables.tf`의 `grafana_version` 기본값도 일치시킨다.

| 이미지 | 베이크 버전 |
| --- | --- |
| grafana/grafana | 11.2.0 |
| quay.io/prometheuscommunity/yet-another-cloudwatch-exporter | v0.67.0 |
| prom/prometheus | v2.54.1 |
| grafana/mimir | 2.13.0 |
| grafana/loki | 3.1.1 |
| grafana/tempo | 2.6.0 |

Compose 플러그인 버전/설치 경로도 `ansible/roles/monitoring/defaults/main.yml`과 `user_data.sh.tftpl`을 함께 갱신한다. 캐시에 같은 이미지 태그가 있으면 `docker compose up -d`가 로컬 이미지를 사용한다. Grafana 버전을 별도로 덮어쓰거나 compose의 버전을 바꾸고 AMI를 다시 굽지 않으면 부팅 중 이미지 pull이 필요하다. 런타임 S3·Secrets Manager·대시보드 다운로드에는 계속 네트워크가 필요하다.

## 로컬 검사 (AWS 리소스 생성 없음)

```bash
terraform -chdir=terraform/modules/monitoring init -backend=false
terraform -chdir=terraform/modules/monitoring validate
terraform -chdir=terraform/environments/prod init -backend=false
terraform -chdir=terraform/environments/prod validate
terraform fmt -check -recursive terraform/modules/monitoring terraform/environments/prod
ansible-playbook --syntax-check packer/monitoring/ansible/playbook.yml
bash packer/monitoring/check.sh
```

`check.sh`는 Terraform console로 두 user_data 경로를 렌더링한 뒤 bash 문법, 설치 생략/가드, 런타임 블록 동일성, 셸 이스케이프, 이미지 버전 동기화를 검사한다. provider·AWS 자격증명이 필요하지 않다. 생성된 `.terraform/`와 모듈의 `.terraform.lock.hcl`은 커밋하지 않는다. prod의 기존 lock 파일은 유지한다.

Packer 설치 환경에서는 위 `packer init`/`packer validate`도 수행한다. validate는 실제 빌드 성공, IAM 권한, 네트워크, 인스턴스 부팅까지 보장하지 않는다.

참고: [Packer amazon-ebs 옵션](https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs), [Terraform aws_ami 필터](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami), [템플릿 지시문과 이스케이프](https://developer.hashicorp.com/terraform/language/expressions/strings).
