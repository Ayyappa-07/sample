variable "role_name" {
  description = "Name of the IAM role for GitHub Actions"
  type        = string
}

variable "github_repositories" {
  description = "List of GitHub repos allowed to assume the role (format: org/repo)"
  type        = list(string)
}

variable "oidc_subject_claims" {
  description = "OIDC sub claims for trust policy. Overrides github_repositories when set. Use for branch restriction (e.g. repo:org/repo:ref:refs/heads/main)"
  type        = list(string)
  default     = []
}

variable "create_oidc_provider" {
  description = "Create the OIDC provider (set to false if it already exists in this account)"
  type        = bool
  default     = true
}

variable "attach_terraform_policy" {
  description = "Attach the Terraform plan/apply policy"
  type        = bool
  default     = true
}

variable "attach_deploy_policy" {
  description = "Attach the ECR push + ECS deploy policy"
  type        = bool
  default     = true
}

variable "terraform_state_bucket" {
  description = "S3 bucket name for Terraform state (used in policy)"
  type        = string
  default     = ""
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs the deploy workflow can push to"
  type        = list(string)
  default     = ["*"]
}

variable "ecs_cluster_arns" {
  description = "ECS cluster ARNs the deploy workflow can update"
  type        = list(string)
  default     = ["*"]
}

variable "ecs_task_role_arns" {
  description = "Task execution + task role ARNs that can be passed during deploy"
  type        = list(string)
  default     = ["*"]
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "log_group_arns" {
  description = "CloudWatch log-group ARNs the CI role may read (DescribeLogStreams/GetLogEvents) to surface failed task logs in Actions output."
  type        = list(string)
  default     = []
}
