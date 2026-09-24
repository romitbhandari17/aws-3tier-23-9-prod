# Use & Importance of KMS and Secrets Manager in This Project

This document explains **why** these two services are used in this
architecture, where each is wired in, and what would break (or become less
secure) without them. For the exact Terraform diff that introduced the KMS
key, see `docs/database-hardening.md`.

---

## 1. AWS Secrets Manager

### What it stores
`modules/rds/main.tf` — `aws_secretsmanager_secret.db` +
`aws_secretsmanager_secret_version.db` create one secret,
`<project>-<environment>-db-credentials`, holding the full DB connection
info as JSON:

```json
{ "username": "...", "password": "...", "host": "...", "port": 5432, "dbname": "..." }
```

### Why it's used instead of plaintext env vars / hardcoded config
- **The DB password never appears in the ECS task definition, container
  image, or application code.** Without Secrets Manager, the password would
  have to be baked into the task definition as a plain environment variable
  — visible to anyone with `ecs:DescribeTaskDefinition` permission (a very
  common, broad permission), and retained in task definition revision
  history indefinitely, even after rotation.
- **Injected at container start, not build time** — `modules/ecs/main.tf`
  wires it into the task definition's `secrets` block:
  ```
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD → valueFrom = "<secret_arn>:<key>::"
  ```
  The ECS agent resolves these at task launch via the `ecs_task_execution_role`
  (see below), and only that resolved value is injected into the running
  container's environment — it's never written to disk, logs, or the task
  definition JSON.
- **Centralizes rotation** — if the DB password changes, only the secret
  needs updating (new `aws_secretsmanager_secret_version`); every consumer
  (ECS tasks) reads the current version automatically on next launch. No
  code or task-definition redeploy needed just to rotate a password.
- **Auditable access** — every `GetSecretValue` call is logged to CloudTrail
  with the calling principal, unlike a value baked into an image or env var.

### Who is allowed to read it (least privilege)
Only two IAM principals can call `secretsmanager:GetSecretValue`, and both
are scoped to this **exact** secret ARN — never `"*"`:
1. `ecs_task_execution_role` (`modules/ecs/iam.tf`) — so the ECS agent can
   resolve the `secrets` block above at task startup.
2. The `secretsmanager` VPC interface endpoint policy
   (`modules/vpc/main.tf`, `data.aws_iam_policy_document.secretsmanager`) —
   so that traffic never has to leave the VPC to reach Secrets Manager (no
   NAT/internet route exists in this VPC at all — see
   `docs/security_opt.md`).

### What would happen without it
The DB password would need to live in the task definition, a `.tfvars` file
read at apply time (still needed today, but only Terraform/operators see
it — not the running container's metadata), or the container image itself
— all strictly worse for both blast radius (who can read it) and rotation
(requires redeploying instead of just updating a secret value).

---

## 2. AWS KMS (Key Management Service)

### The customer-managed key
`modules/rds/main.tf` — `aws_kms_key.rds` (+ `aws_kms_alias.rds` for a
human-readable name, `alias/<project>-<environment>-rds`). See
`docs/database-hardening.md` for the exact lines added.

### What it encrypts
Set as `kms_key_id` on `aws_db_instance.this` with `storage_encrypted =
true`. A single RDS encryption key transparently covers:
- The underlying EBS storage volumes (data at rest).
- Automated backups and manual/final snapshots.
- Any read replicas created from this instance in the future.
- The instance's Enhanced Monitoring/Performance Insights data, if enabled.

### Why a customer-managed key (CMK) instead of the AWS-managed `aws/rds` key
Both encrypt data equally well (same AES-256 encryption under the hood);
the difference is **control**, not strength:
- **Key policy control** — a CMK's IAM/key policy is fully yours to define;
  you decide exactly which principals/roles may `Decrypt`/`GenerateDataKey`
  against it. The AWS-managed key's policy is fixed by AWS and implicitly
  trusts any principal in the account with the relevant service permission.
- **Rotation is explicit and yours** — `enable_key_rotation = true` here
  means AWS automatically rotates the underlying key material yearly, and
  you can see/audit that rotation. This is opt-in and explicit for a CMK.
- **Independent lifecycle** — a CMK can be revoked, disabled, or have its
  policy tightened (e.g. restricted to specific accounts/roles) without
  affecting every other AWS-managed resource in the account that might
  share the default `aws/rds` key.
- **Required for cross-account scenarios** — if this DB's snapshots ever
  needed to be shared with, or restored into, another AWS account, only a
  CMK (not the AWS-managed key) can have its key policy/grants extended to
  allow that.

### Where Secrets Manager and KMS intersect
Secrets Manager secrets are **always** encrypted at rest too — by default
with the AWS-managed `aws/secretsmanager` key (this project does not
currently override that with a CMK; the `aws_secretsmanager_secret.db`
resource has no `kms_key_id` set). The RDS CMK above is separate and only
covers the database storage/backups, not the Secrets Manager secret value
itself.

### What would happen without it
Without `storage_encrypted = true` at all, RDS storage/backups/snapshots
would be stored unencrypted — anyone who could access the underlying
storage layer (e.g. via a leaked/created manual snapshot, or physical media
in a worst-case AWS-internal failure) could read raw data. Without a CMK
specifically (i.e. using the default `aws/rds` key instead), encryption
would still work, but with materially less control over who can decrypt and
no project-scoped ability to revoke access independently of the rest of the
account.

### Cost note
A CMK costs ~$1/month plus a small per-API-call charge (negligible at this
project's traffic). Enabling `storage_encrypted` itself has no RDS
performance or pricing overhead — AWS handles it transparently at the
storage layer.
