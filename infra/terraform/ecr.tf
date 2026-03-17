locals {
  services = toset(["api-python", "api-express", "api-nest", "web"])
}

resource "aws_ecr_repository" "services" {
  for_each = local.services

  name                 = each.key
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
