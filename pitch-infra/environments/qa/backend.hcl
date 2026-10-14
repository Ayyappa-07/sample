bucket         = "pitchai-terraform-state"
key            = "pitchai/qa/terraform.tfstate"
region         = "ap-southeast-2"
encrypt        = true
dynamodb_table = "pitchai-terraform-lock"
