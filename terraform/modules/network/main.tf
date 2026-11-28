locals {
  az_count = length(var.azs)
}

data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# ───────── Subnets (public / app / data) × AZ ─────────
resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-public-${var.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.name}-app-${var.azs[count.index]}", Tier = "app" }
}

resource "aws_subnet" "data" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.data_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.name}-data-${var.azs[count.index]}", Tier = "data" }
}

# 검색·캐시(데이터 서비스) 전용 티어 — OpenSearch 등. AZ 수만큼 서브넷(단일노드는 1개만 사용).
resource "aws_subnet" "search" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.search_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.name}-search-${var.azs[count.index]}", Tier = "search" }
}

# ───────── NAT 인스턴스 (fck-nat, 단일 — NAT Gateway 대비 비용 절감) ─────────
# 1대짜리 ASG(min=max=desired=1) + 고정 ENI(source_dest_check=false, public[0]). 인스턴스가 죽으면 ASG 가
# 새로 띄우고, 부팅 시 fck-nat 서비스가 고정 ENI 를 붙여(라우트 타깃 불변) 기존 EIP 를 다시 연결한다.
# EIP 는 fck-nat 동작상 인스턴스의 기본(eth0) ENI 에 연결된다 — NAT 출구 IP 가 EIP 로 고정된다는 점은 동일.
# ponytail: 단일 AZ·단일 인스턴스라 교체 중 1~2분 egress 단절. 무중단이 필요하면 AZ 별 NAT 인스턴스로 확장.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip" }
}

module "fck_nat" {
  source  = "RaJiska/fck-nat/aws"
  version = "1.3.0" # 1.4.0+ 는 aws provider >= 6.0 요구(이 레포는 ~> 5.0) → 5.x 호환 마지막 버전에 고정

  name          = "${var.name}-nat"
  vpc_id        = aws_vpc.this.id
  subnet_id     = aws_subnet.public[0].id
  instance_type = var.nat_instance_type # arm64(t4g) → 모듈이 fck-nat al2023 arm64 AMI 자동 조회
  ha_mode       = true                  # 1대 ASG 로 자가 복구

  eip_allocation_ids = [aws_eip.nat.id]

  # 프라이빗 RT 의 기본 경로(0.0.0.0/0)를 고정 ENI 로 — aws_route 로 만들므로 RT 에 inline route 를 두지 않는다.
  update_route_tables = true
  route_tables_ids    = { private = aws_route_table.private.id }

  # 부팅 직후 fck-nat 서비스가 AWS API(ENI attach·EIP 연결)를 퍼블릭 경로로 호출하므로 IGW·퍼블릭 RT 가 먼저 있어야 한다.
  depends_on = [aws_route_table_association.public]
}

# ───────── Route tables ─────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# 기본 경로(→ NAT ENI)는 fck_nat 모듈의 aws_route, S3 경로는 게이트웨이 엔드포인트가 넣는다.
# inline route 와 aws_route 를 섞으면 서로 지우는 영구 diff 가 나므로 여기엔 route 블록을 두지 않는다.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "app" {
  count          = local.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "data" {
  count          = local.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "search" {
  count          = local.az_count
  subnet_id      = aws_subnet.search[count.index].id
  route_table_id = aws_route_table.private.id
}

# ───────── S3 게이트웨이 엔드포인트 (무료) ─────────
# 프라이빗 서브넷(앱·데이터·검색 + dev 서브넷 — 같은 RT 연결)의 S3 트래픽(ECR 레이어·미디어·대시보드)이
# NAT 인스턴스를 거치지 않게 한다(대역폭·비용 절감).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3-endpoint" }
}
