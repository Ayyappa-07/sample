bucket         = "pitchai-terraform-state"
key            = "pitchai/prod/terraform.tfstate"
region         = "ap-southeast-2"
encrypt        = true
dynamodb_table = "pitchai-terraform-lock"
