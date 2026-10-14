# Pitch Infrastructure

AWS infrastructure for the Pitch Next.js application — ECS Fargate, RDS PostgreSQL, ElastiCache Redis, ALB, CloudFront, and observability.

## Architecture

- **Networking** — VPC, public/private subnets, NAT gateway, VPC endpoints, flow logs
- **ECS** — Fargate cluster with autoscaling, ARM64/Graviton
- **ECR** — Container registry with lifecycle policy, scan-on-push
- **RDS** — PostgreSQL 17 (Graviton, managed secrets, Performance Insights)
- **ElastiCache** — Redis with auth token, TLS
- **ALB** — Application Load Balancer with WAF
- **CloudFront** — Edge caching for static assets (prod)
- **DNS/TLS** — Route53 + ACM (shared pitch.openn.com zone)
- **SES** — Domain identity + DKIM for email sending
- **CloudTrail** — Audit trail with CloudWatch + S3
- **Observability** — CloudWatch dashboard, SNS alerting, security/cost alarms
- **CI/CD** — GitHub OIDC for Actions, EventBridge cron schedules

## Environments

| Setting           | QA                 | Prod             |
|-------------------|--------------------|------------------|
| Domain            | qa.pitch.openn.com | pitch.openn.com  |
| VPC CIDR          | 10.50.0.0/20       | 10.50.32.0/20    |
| AZs               | 2                  | 3                |
| NAT Gateway       | Single             | Per-AZ           |
| Capacity Provider | FARGATE_SPOT       | FARGATE          |
| Task CPU/Memory   | 512/1024           | 1024/2048        |
| Desired Count     | 1                  | 3                |
| RDS Instance      | db.t4g.medium      | db.r7g.large     |
| Redis Node        | cache.t4g.medium   | cache.r7g.large  |
| CloudFront        | Off                | On               |
| WAF               | On                 | On               |
| Security Alarms   | Off                | On               |

## Usage

```bash
terraform init -reconfigure -backend-config=environments/qa/backend.hcl
terraform plan -var-file=environments/qa/terraform.tfvars
terraform apply -var-file=environments/qa/terraform.tfvars
```

Set `AWS_PROFILE` if using named profiles:

```bash
AWS_PROFILE=pitch terraform plan -var-file=environments/qa/terraform.tfvars
```

## Deploys

All `terraform plan` and `apply` runs are performed manually by DevOps. There is no CI/CD automation for infrastructure — applies stay human-gated.

## Modules

All reusable modules live in `modules/aws/`:

- `networking` — VPC, subnets, NAT, IGW, VPC endpoints, flow logs
- `ecs` — ECS cluster, IAM roles, log group, security group
- `ecr` — ECR repository with lifecycle and encryption
- `rds` — RDS PostgreSQL with subnet group, security group, alarms
- `elasticache` — Redis replication group with auth, TLS
- `s3` — S3 bucket with versioning, lifecycle, CORS
- `secrets` — Secrets Manager entries (shells; values populated manually)
- `waf` — WAFv2 Web ACL for ALB
- `observability` — CloudWatch dashboard, alarms, SNS topics
- `github-oidc` — GitHub Actions OIDC provider + deploy role

## Post-Apply Steps

After `terraform apply` for a new environment:

1. Populate secrets in Secrets Manager (9 app secrets — TF creates the names only)
2. First deploy only: run the bootstrap task (`drizzle-kit push`) to create the DB schema
3. Push container image via CI (triggers ECS deployment + migrations)
4. Verify: `/api/health`, DNS resolution, TLS cert
5. Request SES production access (account-level — sandbox limits apply to all envs until granted). Interim: verify individual test-recipient addresses for qa.
