# IAM note for ALB:
#
# Application Load Balancer does not require a custom IAM role for normal
# operation. AWS automatically creates and manages the service-linked role
# "AWSServiceRoleForElasticLoadBalancing" the first time an ALB/NLB is
# created in the account — no Terraform resource is needed for it.
#
# If access logging to S3 is enabled later, that requires an S3 *bucket
# policy* (not an IAM role) granting the ELB service account/log delivery
# service permission to write objects. That will be added here if/when
# access logging is implemented.
