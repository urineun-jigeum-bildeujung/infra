# ECR 모듈: Docker Image 저장용 ECR Repository 를 정의한다.
#
# 배포 단위 관계 (현재 기준):
#   Spring Boot Application 1 : 1 Docker Image 1 : 1 ECR Repository 1 : 1 K8s Deployment
#
# Source of Truth:
#   백엔드 리포지토리(sever) dev 브랜치의 services/ 디렉터리.
#   존재하지 않는 서비스의 Repository 를 인프라에서 임의로 미리 만들지 않는다.
#   새 서비스가 백엔드에 추가되면 var.repository_names 에 이름만 추가한다.
#   (for_each 기반이므로 기존 Repository 에 영향 없이 신규만 생성된다)
#
# Naming Rule:
#   <project_name>/<service_name>   예: petflow/auth-service
#   - 같은 AWS 계정을 쓰는 다른 프로젝트와의 이름 충돌 방지
#   - ECR 콘솔에서 프로젝트 단위 그룹핑
#   - IAM 정책에서 repository/petflow/* 와일드카드 한 줄로 제어 가능

resource "aws_ecr_repository" "services" {
  for_each = toset(var.repository_names)

  name                 = "${var.project_name}/${each.value}"
  image_tag_mutability = var.image_tag_mutability

  # DEV 는 반복 destroy/apply 를 전제로 하므로 이미지가 남아있어도 삭제 가능하게 둔다.
  force_delete = var.force_delete

  # Push 될 때마다 기본 취약점 스캔 수행
  image_scanning_configuration {
    scan_on_push = true
  }

  # ECR 기본 서버측 암호화. 보안 요구가 생기면 KMS 로 전환한다.
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name    = "${var.project_name}/${each.value}"
    Service = each.value
  }
}

# DEV 용 Lifecycle Policy — 이미지가 무한정 쌓이지 않도록 자동 정리한다.
#   rule 1: untagged 이미지는 N일 후 삭제 (빌드 중간 산출물 정리)
#   rule 2: 이미지 개수가 keep_count 를 초과하면 오래된 것부터 삭제
resource "aws_ecr_lifecycle_policy" "services" {
  for_each = aws_ecr_repository.services

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_expire_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expire_days
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent ${var.lifecycle_keep_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.lifecycle_keep_count
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}
