variable "repository_name" {
  description = "Name of the ECR repository."
  type        = string
}

variable "force_delete" {
  description = "Whether the repository can be deleted even if it contains images."
  type        = bool
  default     = false
}

variable "image_tag_mutability" {
  description = "ECR tag mutability mode."
  type        = string
  default     = "IMMUTABLE"
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN for repository encryption."
  type        = string
  default     = ""
}

variable "image_count_keep" {
  description = "Number of tagged or untagged images to retain in the lifecycle policy."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
