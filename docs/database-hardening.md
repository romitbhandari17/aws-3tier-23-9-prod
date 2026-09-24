# Database Hardening: Multi-AZ + Storage Encryption at Rest

This document lists the concrete Terraform changes made to the RDS module to
enable automatic failover and encrypt data at rest with a customer-managed
KMS key.

⚠️ **Apply impact**: `storage_encrypted` is a `ForceNew` attribute on
`aws_db_instance` — AWS does not support enabling encryption on an existing,
already-provisioned instance in place. The next `terraform apply` will
**destroy and recreate** `module.rds.aws_db_instance.this` to add encryption.
Combined with `skip_final_snapshot = true` (already set, for this demo
environment), **all existing data in the database will be lost** — there is
no snapshot taken before deletion. This is acceptable for this demo project,
but would need a manual final snapshot / pre-migration export for any
environment with real data.

---

## 1. `src/infra/modules/rds/variables.tf`

- **Lines 65–69** (new): added `variable "multi_az"` — `bool`, default
  `true`. Lets an environment opt out via tfvars (e.g. to save cost in a
  disposable demo) while defaulting to hardened behavior everywhere else.

## 2. `src/infra/modules/rds/main.tf`

- **Lines 37–50** (new): `resource "aws_kms_key" "rds"` — customer-managed
  KMS key dedicated to this project's RDS storage encryption (instead of the
  AWS-managed `aws/rds` key), with `enable_key_rotation = true` and a
  7-day deletion window. Using a dedicated key (vs. the account-wide
  AWS-managed key) keeps key policy/rotation/revocation scoped to this
  project instead of shared account-wide.
- **Lines 52–55** (new): `resource "aws_kms_alias" "rds"` —
  `alias/<project>-<environment>-rds`, for a human-readable key reference in
  the console/CLI instead of a bare key ID.
- **Line 110**: `multi_az = false` → `multi_az = var.multi_az` (now `true`
  by default). Provisions a synchronous standby replica in a second AZ with
  automatic failover on primary failure/AZ outage/patching.
- **Lines 111–112** (new): `storage_encrypted = true` and
  `kms_key_id = aws_kms_key.rds.arn` — encrypts the underlying EBS storage,
  automated backups, read replicas, and snapshots with the new
  customer-managed key above.

## 3. `src/infra/modules/rds/outputs.tf`

- **Lines 33–36** (new): added `output "kms_key_arn"` — exposes the new
  key's ARN, e.g. for other modules/tooling that may need to be granted
  `kms:Decrypt` on it later.

---

## Cost/behavior notes

- **Multi-AZ** roughly doubles the RDS instance-hour cost (standby replica
  billed the same as the primary) but adds automatic failover — no
  application changes needed, the DB endpoint hostname stays the same.
- **Storage encryption** has no meaningful performance or cost overhead on
  RDS (AWS handles it transparently at the storage layer); the KMS key
  itself has an ~$1/month + per-request cost, both negligible here.
- Both settings can be reverted per-environment via `-var multi_az=false`
  if needed (encryption cannot be disabled once enabled, by AWS design).
