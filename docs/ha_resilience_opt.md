# ECS High Availability & Resilience: Auto Scaling + Min 2 Tasks

This document lists the concrete Terraform changes made to the ECS module
to replace the hardcoded single-task `desired_count` with Application Auto
Scaling target tracking, and to guarantee a minimum of 2 tasks at all times
(spread across the 2 private-subnet AZs) for zero-downtime rolling deploys
and single-AZ failure tolerance.

---

## 1. `src/infra/modules/ecs/variables.tf`

- **Lines 63–67** (new): `variable "min_capacity"` — `number`, default `2`.
  Floor for Application Auto Scaling; also used as the ECS service's
  initial `desired_count` on first creation.
- **Lines 69–73** (new): `variable "max_capacity"` — `number`, default `4`.
  Ceiling for Application Auto Scaling scale-out.
- **Lines 75–79** (new): `variable "cpu_target_value"` — `number`, default
  `70` (%). Target for the CPU target-tracking policy.
- **Lines 81–85** (new): `variable "memory_target_value"` — `number`,
  default `75` (%). Target for the memory target-tracking policy.

## 2. `src/infra/modules/ecs/main.tf`

- **Line 98**: `desired_count = 1` → `desired_count = var.min_capacity`
  (now `2`). This is only the **initial** count used when the service is
  first created — see the `lifecycle` block below for why it doesn't matter
  after that.
- **Lines 116–121** (new): added a `lifecycle { ignore_changes =
  [desired_count] }` block to `aws_ecs_service.app`. Without this, every
  subsequent `terraform apply` would reset `desired_count` back to
  `var.min_capacity`, undoing whatever count Application Auto Scaling had
  actually scaled the service to in response to real load — Terraform and
  the autoscaler would fight over ownership of this field.
- **Lines 130–136** (new): `resource "aws_appautoscaling_target" "ecs"` —
  registers the ECS service as a scalable target:
  `resource_id = "service/<cluster_name>/<service_name>"`,
  `scalable_dimension = "ecs:service:DesiredCount"`,
  `min_capacity = var.min_capacity` (2), `max_capacity = var.max_capacity`
  (4).
- **Lines 142–155** (new): `resource "aws_appautoscaling_policy" "cpu"` —
  `TargetTrackingScaling` policy using the predefined metric
  `ECSServiceAverageCPUUtilization`, target `var.cpu_target_value` (70%).
  Target tracking manages its own CloudWatch alarms internally — no
  separate `aws_cloudwatch_metric_alarm` resources needed.
- **Lines 161–173** (new): `resource "aws_appautoscaling_policy" "memory"`
  — a second, independent `TargetTrackingScaling` policy alongside the CPU
  one, using `ECSServiceAverageMemoryUtilization`, target
  `var.memory_target_value` (75%). Application Auto Scaling supports
  multiple target-tracking policies on the same scalable target
  simultaneously — it scales out if *either* metric's target is breached,
  and only scales in when *both* are comfortably under target.

---

## Why minimum 2 (not 1) even at low/no traffic

- **Zero-downtime rolling deploys**: with `desired_count = 1`, a deployment
  briefly has 0 old + 1 new (or, depending on timing, a window with only
  the not-yet-healthy new task) — a real request can land on a task that
  isn't ready yet, or on nothing. With 2 tasks, the default rolling update
  (min 100% / max 200% healthy percent) always keeps at least 1 fully
  healthy old task serving traffic while the second one is replaced.
- **AZ failure tolerance**: the ECS service's `subnet_ids` span both
  private-subnet AZs (see `modules/vpc/main.tf`). With 2 tasks, ECS's
  default spread placement strategy runs one task per AZ — if either AZ has
  an outage, the other task keeps serving. With 1 task, an AZ outage is a
  full outage until ECS reschedules elsewhere.

## Why target tracking instead of a fixed count

- Automatically reacts to real load instead of requiring a manual
  `desired_count`/code change and redeploy every time traffic changes.
- Target tracking auto-manages the underlying CloudWatch alarms and scaling
  cooldowns — no hand-written alarm/step-scaling resources to maintain.
- Both CPU and memory are tracked so a memory-bound (or CPU-bound) load
  pattern triggers scale-out either way, rather than only covering one
  dimension.
- Bounded by `min_capacity`/`max_capacity` (2–4 by default) so it can never
  scale below the HA floor above, nor scale out unbounded.

## Cost/behavior notes

- Steady-state cost roughly doubles vs. the previous single-task setup
  (2 tasks minimum instead of 1), before any auto-scale-out.
- `terraform plan`/`apply` will no longer show `desired_count` drift once
  the autoscaler has changed it in AWS — that's the `ignore_changes`
  behavior working as intended, not a bug.
- To temporarily force a specific count for testing, use
  `aws ecs update-service --desired-count <n>` directly (not Terraform) —
  Application Auto Scaling and/or the next scaling evaluation will still
  eventually move it back toward the target-tracking value.
