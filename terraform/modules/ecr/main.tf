# BackEnd 컨테이너 이미지 레지스트리
resource "aws_ecr_repository" "this" {
  name                 = "${var.name}-backend"
  image_tag_mutability = "MUTABLE" # latest 태그 재사용

  image_scanning_configuration {
    scan_on_push = true # push 시 취약점 스캔
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = "${var.name}-backend" }
}

# 오래된 이미지 정리 (최근 10개만 유지)
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최근 10개 이미지만 유지"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
