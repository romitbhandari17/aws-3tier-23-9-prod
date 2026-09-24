# AWS 3-Tier Application — Architecture Context

> Living reference document for this project. Update as decisions evolve.
> Status: **Planning / no code written yet.**

## 1. Overview

A 3-tier web application deployed on AWS using a modern, managed, container-based
architecture:

```
Client
  │
  ▼
API Gateway (Tier 1 - Entry / Edge)
  │
  ▼
Application Load Balancer (ALB)  (Tier 1/2 boundary)
  │
  ▼
ECS (Fargate) Service (Tier 2 - Application/Compute)
  │
  ▼
RDS (Tier 3 - Data)
```

## 2. Tiers

### Tier 1 — Presentation / Edge
- **API Gateway**: Public entry point for client requests (REST or HTTP API).
  Handles routing, throttling, auth (API keys / Cognito / IAM), request
  validation, and possibly VPC Link integration to reach private resources.
- **Application Load Balancer (ALB)**: Sits behind (or is integrated with)
  API Gateway via a VPC Link, or serves as the direct entry point if API
  Gateway is only used for specific routes. Distributes traffic across ECS
  tasks, performs health checks, supports path/host-based routing.

### Tier 2 — Application / Compute
- **ECS (Elastic Container Service)**: Runs the application as containerized
  services.
  - Launch type: Fargate (serverless, no EC2 management) — default assumption
    unless otherwise specified.
  - Deployed across multiple Availability Zones for high availability.
  - Auto Scaling based on CPU/memory/request count.
  - Tasks run in private subnets, registered as ALB target group targets.

### Tier 3 — Data
- **RDS (Relational Database Service)**: Managed relational database
  (engine TBD — e.g., PostgreSQL/MySQL/Aurora).
  - Deployed in private (isolated) subnets, not publicly accessible.
  - Multi-AZ for high availability (production).
  - Access restricted via security groups to ECS tasks only.

## 3. Networking (planned)

- **VPC** with public and private subnets across ≥2 Availability Zones.
  - Public subnets: ALB, NAT Gateway(s).
  - Private (app) subnets: ECS tasks.
  - Private (data) subnets: RDS instances.
- **Security Groups**:
  - ALB SG: allows inbound HTTP/HTTPS from API Gateway/Internet.
  - ECS SG: allows inbound only from ALB SG.
  - RDS SG: allows inbound only from ECS SG on DB port.
- **NAT Gateway**: for outbound internet access from private subnets (e.g.,
  pulling container images, calling external APIs).

## 4. Confirmed Decisions

| Topic | Decision |
|---|---|
| IaC tool | Plain Terraform (no TFE/Terraform Cloud), remote state backend TBD (e.g. S3 + DynamoDB) |
| ECS service language | Python (Flask), minimal demo app |
| Container orchestration | ECS Fargate |

## 5. Open Decisions / To Be Determined

| Topic | Options | Status |
|---|---|---|
| API Gateway type | REST API vs HTTP API | Not decided |
| API Gateway ↔ ALB integration | VPC Link (private ALB) vs public ALB | Not decided |
| Database engine | PostgreSQL / MySQL / Aurora | Not decided |
| Multi-AZ / HA scope | Dev vs Prod parity | Not decided |
| CI/CD | GitHub Actions / CodePipeline | Not decided |
| Container registry | ECR | Assumed |
| Domain/TLS | Route53 + ACM | Not decided |
| Secrets management | Secrets Manager / SSM Parameter Store | Not decided |
| Observability | CloudWatch Logs/Metrics, X-Ray | Not decided |

## 6. Project Structure

```
src/
├── infra/
│   ├── modules/
│   │   ├── vpc/          # VPC, subnets, routing (placeholder)
│   │   ├── alb/           # Application Load Balancer (placeholder)
│   │   ├── ecs/            # ECS cluster/service/task def (placeholder)
│   │   ├── rds/             # RDS instance (placeholder)
│   │   └── apigateway/       # API Gateway + VPC Link (placeholder)
│   └── envs/
│       └── dev/            # Root module wiring the above for the dev env
├── ecs/
│   └── app/                # Minimal Flask demo app + Dockerfile
└── rds/
    └── init.sql             # Placeholder schema/init script
```

All Terraform modules currently contain only `main.tf` / `variables.tf` /
`outputs.tf` stub files with `# TODO` comments — no real resources defined
yet. The Flask app is a minimal "hello world" + `/health` endpoint.

## 7. Repository State

- Directory/file scaffolding created; no real Terraform resources or
  non-trivial application logic yet.
- Existing docs: `docs/local-setup-users-roles.pages` (local setup notes,
  pre-existing).
- This document will be updated as architecture decisions are finalized and
  before further implementation begins.

## 8. Next Steps

1. Confirm API Gateway ↔ ALB integration pattern.
2. Confirm database engine and sizing.
3. Flesh out Terraform modules (vpc → rds → ecs → alb → apigateway, in that
   dependency order) only when explicitly instructed.
4. Define CI/CD pipeline approach.
5. Begin further implementation only after explicit go-ahead.
