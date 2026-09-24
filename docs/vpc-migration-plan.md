# Transitioning to a Private VPC (Future Work)

## Why the earlier attempt got stuck

The private-VPC/VPC-endpoint work in this session (private subnets, VPC
endpoints, `assign_public_ip = false`, IAM least-privilege) was implemented
correctly, but it was applied **in-place, against a live stack** — an
already-running ECS task, ALB, and RDS instance sitting in the default VPC.

Changing `vpc_id` on a security group forces Terraform to replace that
security group. But an ECS Fargate task's ENI, an ALB's ENIs, and an RDS
instance's ENI don't detach the instant the resource that "owns" them is
told to update/replace — AWS needs time to drain traffic and tear down the
network interface. Terraform's dependency graph doesn't wait for that
out-of-band ENI cleanup, so it tries to `DeleteSecurityGroup` while an ENI
is still attached, producing:

```
DependencyViolation: resource sg-xxxx has a dependent object
```

Every fix applied (destroy-time `sleep` provisioners, `wait_for_steady_state`,
`force_new_deployment`, `create_before_destroy`) treated symptoms of the same
root problem: **you cannot safely swap the VPC underneath live, running
compute/database resources.** The ECS service kept rescheduling replacement
tasks onto the *old* security group as fast as they were stopped, because the
service's desired count and network config hadn't actually converged yet —
requiring more and more manual `stop-task`/`update-service --desired-count 0`
intervention.

## The safe approach: migrate into a clean environment, not in-place

Foundational network changes (VPC, subnets, and anything that forces a
security group replacement) should never be applied to a stack with live
traffic. The reliable pattern is:

1. **Fully tear down the current stack first** (`terraform destroy` into an
   empty AWS state) — no resources exist, so there's nothing to drain or race
   against.
2. **Apply the new (private-VPC) config fresh** into that empty environment.
   Every resource is created for the first time; there is no "replace a
   security group out from under a running task" step at all, so none of the
   ENI-detach races can occur.
3. Only after the new stack is confirmed healthy, cut real traffic over to it
   (in this demo's case, since there's only one environment, this just means
   redeploying fresh rather than mutating live infra).

This is effectively a blue/green approach applied to infrastructure: destroy
the "blue" (default-VPC) stack, then create a brand new "green" (private-VPC)
stack, rather than trying to morph blue into green while it's still serving
traffic.

## Recommended next steps (when ready to revisit this)

1. Re-apply the private-VPC module work (it's preserved in git history /
   `docs/network-isolation.md` from this session — the `modules/vpc` build-out,
   ECS `assign_public_ip = false`, VPC endpoint SGs, and the IAM
   least-privilege hardening were all functionally correct).
2. Before applying, run a full `terraform destroy` against the **current**
   (default-VPC) stack so the environment is empty.
3. Run `terraform apply` once, from a clean state, with the private-VPC
   config. Expect no manual `stop-task`/SG-deletion intervention to be
   needed, since nothing is being replaced — only created.
4. Skip the destroy-time `sleep` provisioners and `create_before_destroy`
   lifecycle blocks added during the in-place attempt — they were workarounds
   for the live-migration race and add unnecessary complexity/slowness to a
   fresh-create workflow. (If you ever need to change the VPC again after
   this point, revisit that pattern — or better, plan another full
   destroy/recreate cycle instead.)
5. If ENI-detach delays are ever unavoidable in a future in-place change,
   prefer polling `aws ec2 describe-network-interfaces` for zero attached
   ENIs over a fixed `sleep`, and drain the ECS service explicitly
   (`update-service --desired-count 0` + `wait services-stable`) *before*
   `terraform apply`/`destroy` even starts, rather than relying on Terraform
   to sequence the drain itself.

## Current status

The repository has been reverted to the original default-VPC configuration
(commit `5c754c7`). No infra code changes remain from the private-VPC
attempt. `docs/network-isolation.md` documents what was built, in case this
work is picked up again later.
