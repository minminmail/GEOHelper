# Smallest pilot setup for the GEO monitoring tool:
#   1 x EC2 (Caddy + web app + worker in Docker), Elastic IP, no load balancer, no NAT
#   1 x RDS PostgreSQL (private), S3 bucket, SQS queue + DLQ,
#   EventBridge Scheduler (monthly run), SSM parameters for API keys,
#   CloudWatch log group, AWS Budget alert.
# Uses the account's default VPC to keep it simple.

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  bucket_name = "${var.name}-${data.aws_caller_identity.current.account_id}-${random_id.suffix.hex}"
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "GEO app server: HTTP/HTTPS in, all out. No SSH (use SSM Session Manager)."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP (Caddy redirects to HTTPS and answers ACME challenges)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound to LLM APIs, AWS services, package repos"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "PostgreSQL, reachable only from the app server"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Postgres from app server"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

# ---------------------------------------------------------------------------
# Storage: S3 for raw answer archive and PDF reports
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "data" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "raw-answers-to-cheaper-storage"
    status = "Enabled"
    filter {
      prefix = "raw/"
    }
    transition {
      days          = 180
      storage_class = "GLACIER_IR"
    }
  }
}

# ---------------------------------------------------------------------------
# Database: RDS PostgreSQL (private, password managed in Secrets Manager)
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "db" {
  name       = "${var.name}-db"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.name}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage     = var.db_storage_gb
  max_allocated_storage = var.db_storage_gb * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                     = "geo"
  username                    = "geo_admin"
  manage_master_user_password = true # password lives in Secrets Manager, never in tfstate

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.name}-db-final"
}

# ---------------------------------------------------------------------------
# Job queue: SQS + dead-letter queue
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${var.name}-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${var.name}-jobs"
  visibility_timeout_seconds = 900 # a client run can take a while; worker extends it if needed
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20 # long polling
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 3
  })
}

# ---------------------------------------------------------------------------
# Monthly schedule: EventBridge Scheduler -> SQS
# The worker treats {"type":"monthly_run"} as "enqueue one job per active client".
# ---------------------------------------------------------------------------

resource "aws_iam_role" "scheduler" {
  name = "${var.name}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_send" {
  name = "send-to-jobs-queue"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.jobs.arn
    }]
  })
}

resource "aws_scheduler_schedule" "monthly_run" {
  name                         = "${var.name}-monthly-run"
  schedule_expression          = var.monthly_run_cron
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.jobs.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ type = "monthly_run" })
  }
}

# ---------------------------------------------------------------------------
# Secrets: one SSM SecureString per LLM provider.
# Created with a placeholder; set the real key with the AWS CLI (see README).
# Terraform ignores later value changes, so real keys never enter tfstate.
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "llm_api_key" {
  for_each = toset(var.llm_providers)

  name  = "/${var.name}/${each.key}_api_key"
  type  = "SecureString"
  value = "CHANGE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.name}/app"
  retention_in_days = 30
}

# ---------------------------------------------------------------------------
# EC2 instance role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app" {
  name = "${var.name}-app"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "JobsQueue"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = [aws_sqs_queue.jobs.arn, aws_sqs_queue.jobs_dlq.arn]
      },
      {
        Sid      = "DataBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.data.arn
      },
      {
        Sid      = "DataBucketObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.data.arn}/*"
      },
      {
        Sid      = "LlmApiKeys"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name}/*"
      },
      {
        Sid      = "DbPassword"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_db_instance.postgres.master_user_secret[0].secret_arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "${aws_cloudwatch_log_group.app.arn}:*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.name
}

# ---------------------------------------------------------------------------
# EC2: one ARM instance running Caddy + app + worker via Docker Compose
# ---------------------------------------------------------------------------

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # lets containers get the instance role credentials
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region    = var.region
    name      = var.name
    queue_url = aws_sqs_queue.jobs.url
    bucket    = aws_s3_bucket.data.bucket
    db_host   = aws_db_instance.postgres.address
    db_name   = aws_db_instance.postgres.db_name
    db_secret = aws_db_instance.postgres.master_user_secret[0].secret_arn
    log_group = aws_cloudwatch_log_group.app.name
  })
  user_data_replace_on_change = false

  tags = {
    Name = "${var.name}-app"
  }

  lifecycle {
    ignore_changes = [ami] # don't replace the server when a newer AMI is published
  }
}

resource "aws_eip" "app" {
  domain   = "vpc"
  instance = aws_instance.app.id
  tags = {
    Name = "${var.name}-app"
  }
}

# ---------------------------------------------------------------------------
# Cost guard
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}
