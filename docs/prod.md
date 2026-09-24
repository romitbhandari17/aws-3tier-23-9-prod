# Production Readiness Guide

> Companion to `docs/architecture-context.md`. That doc describes the current
> **dev/demo** setup; this doc lists what must change before this stack is
> promoted to a production environment. No code is changed here — this is a
> checklist/design doc to drive future implementation work.

## 1. Current State Summary (dev/demo shortcuts)

These are intentional simplifications in the current code that are **not**
production-appropriate:

| Area | Current (dev) | Risk if shipped to prod |
|---|---|---|
| Networking | Uses AWS account's **default VPC**; no custom subnets/route tables | No real network isolation between tiers; blast radius is the whole default VPC |
| NAT / egress | No NAT Gateway; ECS tasks get **public IPs** (`assign_public_ip = true`) to reach ECR | App containers directly internet-routable; larger attack surface |
| TLS | ALB listener is **HTTP only** (port 80); API Gateway default endpoint is HTTPS but ALB leg is plaintext | Data in transit unencrypted between API GW and ALB/ECS |
| Secrets | DB password passed via `dev.tfvars` / `TF_VAR_db_password`, no rotation | Risk of leaked long-lived static credential |
| RDS HA | `multi_az = false`, `backup_retention_period = 0`, `skip_final_snapshot = true` | No failover; **zero backups**; data loss on any DB incident |
| RDS sizing | `db.t3.micro`, `gp2`, 20 GB, single instance | Insufficient for real load; burstable credits exhaust under sustained traffic |
| ECS sizing/scaling | Fixed `desired_count = 1`, `cpu=256`, `memory=512`, no autoscaling policy | No HA (single task), no elasticity for traffic spikes |
| ECS deployment | `image_tag_mutability = "MUTABLE"` on ECR; deploys via ad-hoc script + `terraform apply` | Tag `latest` can be overwritten/ambiguous; no audited pipeline |
| Observability | CloudWatch log group only, 7-day retention; no metrics alarms, dashboards, tracing | Blind to incidents; no alerting; short audit trail |
| State management | No remote Terraform backend configured (local `terraform.tfstate` is even committed in repo) | State loss/corruption risk; no locking; **state file with resource details is in git** |
| Environments | Only `envs/dev` exists; no `staging`/`prod` tfvars or workspace separation | No safe promotion path; prod would reuse dev config verbatim |
| WAF / edge protection | None on API Gateway | No protection from common web exploits, bots, L7 DDoS |
| IAM | ECS task role has no policies (fine for now, but no least-privilege prod policy defined yet) | Needs explicit scoping once app does real AWS calls |

## 2. Environment & Configuration Changes

- **Separate environments**: add `envs/staging` and `envs/prod` directories
  with their own `.tfvars` (mirroring `envs/dev`), each with its own
  `project_name`/`environment` values so resource names, log groups, and
  secrets don't collide across environments.
- **Remote state backend**: configure the commented-out `backend "s3"` block
  in `provider.tf` — S3 bucket with versioning + encryption, and a
  DynamoDB table (or S3-native locking) for state locking. One state
  path per environment (e.g. `env:/prod/terraform.tfstate`).
- **Stop committing state**: remove `terraform.tfstate` /
  `terraform.tfstate.backup` from version control and ensure `.gitignore`
  covers them (they can contain secrets in plaintext).
- **Secrets via pipeline, not tfvars**: inject `db_password` (and other
  sensitive vars) from a secrets manager / CI secret store at apply time
  (e.g. `TF_VAR_db_password` sourced from GitHub Actions secrets or AWS
  Secrets Manager), never checked into any tfvars file for prod.
- **Custom VPC per environment**: replace the default-VPC lookup in
  `main.tf` with the (currently placeholder) `vpc` module — real public,
  private-app, and private-data subnets across ≥2 AZs, matching the
  architecture doc's original design.
- **Config drift control**: enforce `terraform plan` review + approval gate
  before `apply` in prod (see CI/CD section).

## 3. Security Hardening

- **Network isolation**
  - Deploy ECS tasks into private subnets with **no public IP**
    (`assign_public_ip = false`) and no route to the internet at all.
  - Prefer **VPC Endpoints over a NAT Gateway** for this app's outbound
    needs, since everything it talks to is AWS-managed, not third-party
    internet: private, fully covers current requirements, and is typically
    cheaper than NAT at this traffic scale (see cost section).
    - **Interface endpoints** (one per AZ used): `ecr.api`, `ecr.dkr`
      (image pulls), `logs` (CloudWatch Logs shipping), `secretsmanager`
      (DB credential retrieval by the task execution role).
    - **Gateway endpoint** (no hourly cost): `s3` — required alongside
      `ecr.dkr`, because ECR stores image layers in S3; image pulls fail
      without it even with the ECR interface endpoints in place.
    - Attach a security group to the interface endpoints allowing HTTPS
      (443) inbound from the ECS task security group only.
    - Add endpoint policies scoping each interface endpoint to the specific
      ECR repo / log group / secret ARN this app needs, rather than
      allowing account-wide access through the endpoint.
    - Only fall back to a NAT Gateway if/when the app needs to reach
      non-AWS (third-party) endpoints over the internet — no such need
      exists today.
  - Deploy RDS into isolated private/data subnets with no route to the
    internet at all (no endpoint needed here — ECS→RDS traffic stays
    within the VPC via security groups already).
  - Keep ALB internal (already the case) — API Gateway VPC Link remains the
    only public ingress path.
- **TLS everywhere**
  - Terminate TLS at API Gateway with a custom domain + ACM certificate
    (Route 53 + ACM), which the architecture doc already lists as an open
    decision.
  - Add an HTTPS listener on the ALB (ACM cert) and consider re-encrypting
    the VPC Link → ALB hop, not just the client → API Gateway hop.
- **WAF**: attach AWS WAFv2 to the API Gateway stage (rate limiting, managed
  rule groups for common exploits/bots) before it's public-facing.
- **Secrets management**
  - Continue using Secrets Manager for DB credentials (already in place),
    but add **automatic rotation** (`aws_secretsmanager_secret_rotation`)
    for prod.
  - Avoid ever passing secrets as plain container **environment variables**
    beyond the existing `secrets` block pattern (already correct — keep it).
- **IAM least privilege**
  - Define an explicit, minimal task role policy once the app needs real
    AWS API access (currently empty) — never attach broad managed policies.
  - Review the ECS task execution role's Secrets Manager policy to scope
    to the specific secret ARN only (already scoped — verify it stays that
    way per environment).
  - Review `docs/deploy-iam-policy.json` (deployer IAM policy) for
    least-privilege scoping before use with a prod deployment principal;
    prefer a dedicated CI/CD role over long-lived human credentials.
- **ECR image integrity**
  - Switch `image_tag_mutability` to `IMMUTABLE` for prod so a tag can never
    silently point to different image content.
  - Enable ECR image scanning on push and gate deploys on scan results.
  - Avoid deploying `latest`; pipeline should deploy by immutable digest or
    commit-SHA tag only (the deploy script already tags by short SHA — make
    this the *only* prod deploy path, not `latest`).
- **Database hardening**
  - Enable Multi-AZ (`multi_az = true`) for automatic failover.
  - Set `backup_retention_period` to a real value (e.g. 7–35 days) and stop
    using `skip_final_snapshot = true` in prod.
  - Enable storage encryption at rest (`storage_encrypted = true` with a
    customer-managed KMS key) if not already default.
  - Enable RDS enhanced monitoring and Performance Insights.
  - Restrict `publicly_accessible` (already `false` — keep it) and audit
    security group rules regularly.
- **Audit & compliance**
  - Enable CloudTrail (org-wide or account-level) if not already on.
  - Enable AWS Config rules for drift/compliance checks on security groups,
    encryption, public exposure.
  - Enable VPC Flow Logs on the prod VPC.

## 4. High Availability & Resilience

- **ECS**
  - Raise `desired_count` to ≥2 (spread across ≥2 AZs) and add an
    Application Auto Scaling policy on ECS service (target tracking on
    CPU/memory or ALB request count per target) instead of a hardcoded
    replica count.
  - Consider a minimum of 2 tasks even at low traffic for zero-downtime
    rolling deploys and AZ failure tolerance.
  - Set an ECS deployment circuit breaker with rollback so a bad deploy
    auto-reverts instead of pinning a broken revision.
- **RDS**: Multi-AZ (as above) is the primary lever; consider read replicas
  only if/when read traffic requires it (avoid over-provisioning upfront).
- **ALB**: already spans subnets across AZs — verify prod subnets used are
  ≥2 AZs (same constraint the RDS/VPC-Link modules already enforce).
- **Health checks**: verify ALB target group health check path/thresholds
  are tuned for real app startup time (current: 30s interval, 2 healthy /
  3 unhealthy — fine as a default, revisit after load testing).

## 5. Observability

- **Logs**: increase CloudWatch log retention beyond 7 days for prod (e.g.
  30–90 days depending on compliance needs) and consider exporting to S3
  for longer/cheaper retention.
- **Metrics & alarms**: add CloudWatch Alarms for ECS CPU/memory
  utilization, RDS CPU/connections/storage, ALB 5xx rate and target health,
  API Gateway 4xx/5xx and latency — wire to SNS → on-call notification.
- **Dashboards**: a single CloudWatch dashboard per environment summarizing
  the above.
- **Tracing**: add AWS X-Ray (or OpenTelemetry) instrumentation through API
  Gateway → ALB → ECS for latency/error root-causing, per the architecture
  doc's open decision on observability.
- **Structured app logs**: current Flask app uses default logging; adopt
  structured (JSON) logs before scaling out multiple tasks, so log
  aggregation/filtering stays usable.

## 6. Cost Optimization

- **Right-size before scaling out, not up**: keep ECS task `cpu`/`memory`
  at the smallest size that meets latency SLOs, and rely on horizontal
  autoscaling (more small tasks) rather than large tasks, for better
  granularity and resilience.
- **RDS instance class**: `db.t3.micro` is fine for low-traffic prod; move
  to `db.t3.small`/`db.t4g.medium` (Graviton = cheaper/perf-per-$) only if
  metrics show CPU credit exhaustion or connection limits under real load.
  Prefer Graviton (`db.t4g.*`, `db.m7g.*`) instance families for better
  price/performance over Intel equivalents.
- **Storage**: reassess `gp2` vs `gp3` for RDS storage — `gp3` is generally
  cheaper at the same performance and allows independent IOPS/throughput
  tuning without over-provisioning storage size just to get more IOPS.
- **NAT Gateway vs VPC Endpoints**: since this app's only outbound targets
  are AWS services (ECR, CloudWatch Logs, Secrets Manager), VPC Endpoints
  (interface + the S3 gateway endpoint) avoid NAT Gateway entirely —
  no NAT hourly charge (~$0.045/hr per AZ) or its $0.045/GB processing fee,
  and Gateway endpoints (S3) have no cost at all. Interface endpoints do
  have their own hourly (~$0.01/hr per AZ) + per-GB (~$0.01/GB) cost, but
  at this app's traffic volume that's materially cheaper than NAT, on top
  of the security benefit of no internet route. Only introduce a NAT
  Gateway later if the app starts calling non-AWS third-party APIs.
- **Fargate vs Fargate Spot**: for non-critical / retry-tolerant workloads,
  use Fargate Spot capacity providers for a subset of tasks to cut compute
  cost; keep a baseline of standard Fargate tasks for guaranteed capacity.
- **Log retention**: CloudWatch Logs storage cost scales with retention —
  balance the "increase retention" recommendation above against actual
  compliance needs; export older logs to S3 (cheaper storage classes)
  instead of indefinitely retaining in CloudWatch.
- **ECR**: add a lifecycle policy to expire untagged/old images so storage
  cost doesn't grow unbounded from every CI build.
- **Autoscaling to zero for non-prod**: keep this cost-saving pattern for
  `dev`/`staging` only (e.g. scheduled scale-down after hours) — do **not**
  apply to prod, but call it out here since prod tfvars will diverge from
  dev/staging specifically on this point.
- **Budgets & alerts**: set up AWS Budgets with alerts per environment/tag
  to catch cost regressions early (e.g. an accidental Multi-AZ + oversized
  instance combo).
- **Tagging for cost allocation**: ensure every resource carries
  `Project`/`Environment` tags consistently (already done for RDS; extend
  to all modules) so Cost Explorer can break down spend per environment.

## 7. Resource Optimization

- **Connection pooling**: the Flask app opens a fresh Postgres connection
  per request (`get_db_connection`, not pooled) — acceptable at demo
  traffic, but before prod introduce connection pooling (e.g.
  `psycopg2.pool`, PgBouncer, or RDS Proxy) to avoid exhausting RDS
  `max_connections` once multiple ECS tasks run concurrently.
- **RDS Proxy**: consider AWS RDS Proxy in front of RDS for prod — pools
  and multiplexes connections across scaled-out ECS tasks, and improves
  failover time during Multi-AZ events.
- **Task sizing feedback loop**: use CloudWatch Container Insights (ECS)
  to observe real CPU/memory utilization and iteratively right-size `cpu`/
  `memory` rather than guessing.
- **Autoscaling policies**: prefer target-tracking scaling policies (e.g.
  70% CPU target) over step scaling for simpler, self-tuning behavior.
- **Idle resource cleanup**: ensure the ECR lifecycle policy (above) and any
  orphaned CloudWatch log groups/target groups from decommissioned
  environments are cleaned up via Terraform (destroy unused `envs/*` fully
  rather than leaving partially-applied state).

## 8. CI/CD & Deployment Process

- Replace the manual `scripts/deploy-ecs.sh` flow for prod with a proper
  pipeline (GitHub Actions or CodePipeline, per the still-open decision in
  the architecture doc):
  - Build & scan image → push to ECR with immutable commit-SHA tag →
    `terraform plan` (posted for review) → manual approval gate → `apply`.
  - Never run `terraform apply -auto-approve` against prod state without a
    human-reviewed plan.
- Add a `terraform validate` + `fmt -check` + `tflint`/`checkov` (or
  similar static analysis) step to catch misconfigurations (e.g. public
  RDS, missing encryption) before they reach prod.
- Separate IAM roles/credentials per environment for the CI/CD pipeline,
  scoped to only what that environment's deploy needs (see
  `docs/deploy-iam-policy.json` as the starting point to narrow down).

## 9. Suggested Prioritization

If tackled incrementally, roughly in order of risk reduction per effort:

1. Remove committed `terraform.tfstate*` from git; add remote backend.
2. Stop using default VPC; private subnets + NAT for ECS, isolated subnets
   for RDS.
3. Enable RDS Multi-AZ, backups, and encryption; stop `skip_final_snapshot`.
4. Add TLS end-to-end + WAF on API Gateway.
5. ECS: ≥2 tasks, autoscaling, deployment circuit breaker.
6. Observability: alarms + dashboards + longer log retention.
7. CI/CD pipeline with plan/approve gate, immutable image tags.
8. Cost tuning pass once real traffic/metrics exist (right-size, gp3,
   Fargate Spot, ECR lifecycle policy, budgets).
