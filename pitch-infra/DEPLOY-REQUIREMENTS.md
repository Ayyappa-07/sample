# Pitch AI — Terraform deltas to actually run the app on ECS

Status of the current root config (`main.tf`): provisions VPC, ECS **cluster + roles**
(no service/taskdef), RDS Postgres, an **nginx placeholder** task-def + service (NOT the
app), a `migrations` task-def, ECR, and observability. To run the real Next.js app we need
the items below. App runtime facts are pinned in the Pitch repo (`Dockerfile`,
`docker-entrypoint.sh`, `src/lib/config.ts`).

Region is **`ap-southeast-2` (Sydney)**. App container listens on **port 5000**. LB health
check path is **`GET /api/health`** (liveness, no DB — do NOT use `/api/health/ready`).

**Architecture: ARM64 (Graviton) end-to-end.** Fargate runs the tasks on ARM64 (cheaper +
better price/perf), CI builds natively on a GitHub arm64 runner (`ubuntu-24.04-arm`), and local
builds on Apple Silicon are already arm64 — so no QEMU emulation anywhere. The **app and
migration task defs must** set `runtime_platform { cpu_architecture = "ARM64",
operating_system_family = "LINUX" }`, or ECS refuses to start the arm64 image with "image
manifest does not match platform". (The Dockerfile itself needs no change — the base image is
multi-arch and `sharp` ships arm64 prebuilds.)

---

## 1. Domain + TLS  →  `pitch.openn.com`

- **Reuse `*.openn.com` ACM cert IF it exists in `ap-southeast-2`** (regional ALB requires the
  cert in the ALB's own region — a wildcard issued in us-east-1 for CloudFront will NOT attach):
  ```hcl
  data "aws_acm_certificate" "wildcard" {
    domain      = "*.openn.com"
    statuses    = ["ISSUED"]
    most_recent = true
  }
  ```
  Otherwise request one for `pitch.openn.com` (DNS-validated) + the validation records.
- `data "aws_route53_zone" "openn" { name = "openn.com" }` + an **A/alias** record
  `pitch.openn.com` → the ALB.
- Set `NEXT_PUBLIC_APP_URL = https://pitch.openn.com` — used both as the **docker build-arg**
  (baked into the bundle for OG tags / canonical proposal URLs) **and** as a runtime env on
  the app task.

## 2. ALB + target group + listeners  (entirely missing today)

- `aws_lb` (application) in the **public** subnets.
- `aws_security_group` "alb": ingress 443 + 80 from `0.0.0.0/0`, egress all.
- `aws_lb_target_group`: `target_type = "ip"` (Fargate awsvpc), port **5000**, protocol HTTP,
  health check path **`/api/health`**, matcher 200, interval ~15–30s.
- `aws_lb_listener` **443**: cert = the ACM cert above; default action forward → target group.
- `aws_lb_listener` **80**: redirect → 443.
- **SG rule**: app-tasks SG ingress on **5000 from the ALB SG** (the ecs module's tasks SG
  currently only allows `var.vpc_cidr` — tighten to the ALB SG).

## 3. App task definition + service  (replace the nginx placeholder)

- New `aws_ecs_task_definition` family **`pitchai-app`**, container name **`app`**,
  `image = var.app_image` (the ECR image CI pushes), `portMappings` containerPort **5000**,
  `cpu`/`memory` (e.g. 512 / 1024 to start), **`stopTimeout = 30`**, and
  `linuxParameters.initProcessEnabled = true` (clean zombie reaping / signal handling — the
  app drains + closes the PG pool/Redis on SIGTERM in ~≤25s).
- `aws_ecs_service` **`pitchai-app`** with a **`load_balancer`** block
  (`target_group_arn`, `container_name = "app"`, `container_port = 5000`),
  `health_check_grace_period_seconds` ~90, private subnets, `assign_public_ip = false`.
- **Rebind the existing autoscaling** target/policy from the nginx service to this one, then
  delete `aws_ecs_task_definition.nginx` + `aws_ecs_service.nginx`.

### App task env (plain, non-secret)

| Env | Value |
|---|---|
| `NODE_ENV` | `production` |
| `NEXT_PUBLIC_APP_URL` | `https://pitch.openn.com` |
| `AWS_S3_BUCKET` | the uploads bucket name (§5) |
| `AWS_S3_REGION` | `ap-southeast-2` — matches the app default and the bucket region (still set it explicitly) |
| `REDIS_URL` | `redis://<elasticache-primary-endpoint>:6379` (§4) |
| `PG_HOST` `PG_PORT` `PG_USER` `PG_DBNAME` | from RDS module outputs (entrypoint builds `DATABASE_URL` from these + `PG_PASS`) |
| `PG_SSL` | `require` |
| `PG_POOL_MAX` | e.g. `10` — keep `max_tasks × PG_POOL_MAX` < RDS `max_connections` |
| `SES_FROM_EMAIL` | a **verified** SES identity (e.g. `updates@openn.com`) |

### App task secrets (Secrets Manager `valueFrom`)

These are **application / third-party secrets, not AWS credentials** — an IAM role cannot
produce an Anthropic API key, a Browserless key, an HMAC secret, or the DB password, so they
have to live in a store and get injected at container start. The task's **execution role** is
what's authorized to read them (still 100% IAM-role-based; **no AWS access keys anywhere**).
Name every secret with the **`pitchai/` prefix** (e.g. `pitchai/anthropic-api-key`) so the
execution role's existing `secret:pitchai/*` policy can read it. (SSM Parameter Store
SecureStrings work identically via the same role and are cheaper, if you prefer them.)

| Secret env | Source | Required? |
|---|---|---|
| `PG_PASS` | RDS managed secret `${module.rds.master_user_secret_arn}:password::` | yes (needs IAM fix §6) |
| `VIEWER_IDENTITY_SECRET` | `pitchai/viewer-identity-secret` (≥32 chars) | **yes — app won't boot without it** |
| `ANTHROPIC_API_KEY` | `pitchai/anthropic-api-key` | yes (AI) |
| `BROWSERLESS_API_KEY` | `pitchai/browserless-api-key` | yes (PDF export) |
| `CRON_SECRET` | `pitchai/cron-secret` | yes (cron endpoints) |
| `AI_INTEGRATIONS_OPENAI_API_KEY` | `pitchai/openai-api-key` | if DALL·E image gen is used |
| `ADMIN_SECRET`, `DOMAIN_API_KEY`/`DOMAIN_CLIENT_ID`/`DOMAIN_CLIENT_SECRET`, `SNS_SENDER_ID` | as needed | optional |

> AWS auth for S3/SES/SNS is via the **task role** (§5) — no `AWS_ACCESS_KEY_ID/SECRET` needed;
> the app now uses the SDK default credential chain when a role is present.

## 4. ElastiCache (Redis)

- `aws_elasticache_subnet_group` (private subnets) + `aws_security_group` "redis" (ingress
  6379 from the app-tasks SG).
- `aws_elasticache_replication_group` (or cluster), **t4g.micro**, engine `redis`, 1 node to
  start. Keep it non-TLS in-VPC → `REDIS_URL = redis://<primary>:6379`.
- ⚠️ The app **boot-aborts if `REDIS_URL` is set but unreachable**, so the SG/endpoint must be
  correct before the app service comes up.
- Output the primary endpoint to build `REDIS_URL`.

## 5. S3 bucket + task-role IAM

- `aws_s3_bucket` for uploads.
- **Object read model — decision needed:** the app returns plain public URLs
  (`https://<bucket>.s3.<region>.amazonaws.com/<key>`). For those to load in browsers either
  (a) a bucket policy granting `s3:GetObject` to `*` on `arn/*` (public-read objects; adjust
  the public-access-block accordingly), or (b) front the bucket with CloudFront + OAC (cleaner,
  cacheable) and rewrite the returned base URL. (a) is fastest to launch.
- **Task role** (`module.ecs.task_role`) needs, via a root `aws_iam_role_policy`:
  - S3: `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` on `<bucket-arn>/*`
  - SES: `ses:SendEmail`, `ses:SendRawEmail`
  - SNS: `sns:Publish`

## 6. IAM fixes (two current bugs)

1. **Execution role can't read the RDS secret.** Its inline policy is scoped to
   `secret:pitchai/*`, but the RDS-managed secret is named `rds!db-…` → `PG_PASS` injection
   fails with AccessDenied on **both** the app and migration tasks. Add a root
   `aws_iam_role_policy` on `module.ecs.task_execution_role` granting
   `secretsmanager:GetSecretValue` on `module.rds.master_user_secret_arn` (+ `kms:Decrypt`
   for the RDS secret's KMS key).
2. Keep app secrets under the `pitchai/` prefix so they're already covered (no extra policy).

## 7. Migration task

- Set `app_image` to the ECR image (CI passes the new tag per deploy).
- It reuses the same image (has `psql` + `tsx` + `src/db/migrations` + `scripts/`).
- You can drop the inline `DATABASE_URL` construction in its `command` and just pass
  `PG_*` + `PG_PASS` like the app task — the image entrypoint builds `DATABASE_URL`. Either
  way works.
- Run it as a **one-off** (CI does `run-task` before updating the service); it's already a
  task-def, not a service. ✔
- **First deploy against a fresh RDS needs a one-time bootstrap first:** run the same task-def
  with command `npx drizzle-kit push` (or `npm run db:push`) **before** `post-merge.sh`. The SQL
  migrations start at 004 and only `ALTER` existing tables — the base tables come from Drizzle's
  `schema.ts` via `db:push`. Without this, the very first migration run fails on missing tables.
  drizzle-kit + drizzle.config.ts are already in the image. Subsequent deploys: `post-merge.sh` only.

## 8. Housekeeping

- **Region → Sydney.** Set `terraform.tfvars` `region = "ap-southeast-2"` and change the
  `variables.tf` subnet AZ defaults from `ap-south-1a/1b` to `ap-southeast-2a/2b` (add `2c`
  if you want 3 AZs). Confirm the `rds_engine_version` / instance class are offered in
  ap-southeast-2 (they are for pg16 / t3/t4g). The ACM cert and S3 bucket also live here.
- Add an **S3 backend** to the root (state is local today). The `environments/*` dirs already
  reference bucket `skybytech-terraform-state` + DynamoDB `terraform-locks` — reuse with key
  `pitchai/prod/terraform.tfstate`.
- Fix `variables.tf` default `ecr_repository_name = "test-ecs-app"` → `pitchai-app`.
- Delete or repair the stale `environments/dev|prod` roots (their module sources
  `../../../terraform/modules` don't resolve and they describe a different "test-ecs" project).
- Add outputs: ALB DNS name, app URL (`https://pitch.openn.com`), Redis endpoint, S3 bucket.

## 9. Hand-off to CI (after infra is up)

The GitHub Actions deploy workflow will need these to line up with the names above:
- OIDC deploy role ARN with: ECR push, `ecs:RegisterTaskDefinition`/`RunTask`/`UpdateService`/
  `DescribeServices`/`DescribeTasks`, and `iam:PassRole` for the task + execution roles.
- Names: cluster `pitchai`, ECR repo `pitchai-app`, app service `pitchai-app`, app task family
  `pitchai-app`, migration task family `pitchai-migrations`.
- Build-arg `NEXT_PUBLIC_APP_URL=https://pitch.openn.com`.
