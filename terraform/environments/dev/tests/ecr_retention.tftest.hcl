mock_provider "aws" {}

run "repositories_disable_force_delete" {
  command = plan

  module {
    source = "../../modules/ecr"
  }

  variables {
    project_name     = "petflow"
    repository_names = ["auth-service", "web"]
  }

  assert {
    condition = alltrue([
      for repository in aws_ecr_repository.services :
      repository.force_delete == false
    ])
    error_message = "ECR Repository는 이미지 강제 삭제를 허용하면 안 됩니다."
  }
}
