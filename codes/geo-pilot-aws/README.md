# GEO monitoring tool – smallest AWS pilot

One EC2 server runs everything in Docker (Caddy for HTTPS, the web app, the worker).
RDS PostgreSQL stores configs, answers and metrics; S3 stores raw archives and PDF reports;
SQS + EventBridge Scheduler start the monthly run. No load balancer, no NAT gateway.

```
Agency team ──HTTPS──> Elastic IP ─> EC2 (t4g.small)
                                      ├─ caddy   (Let's Encrypt)
                                      ├─ api     (FastAPI + dashboard)
                                      └─ worker  (SQS -> LLM APIs -> RDS/S3)
EventBridge Scheduler (1st of month) ──> SQS jobs queue (+ DLQ)
RDS PostgreSQL (private) · S3 · SSM Parameter Store (API keys) · CloudWatch Logs · Budget alert
```

Region: `eu-south-2` (Spain). Change `region` in `terraform.tfvars` if needed.

## What it costs (rough)

EC2 t4g.small + RDS db.t4g.micro + 20 GB storage + Elastic IP make up almost all of it:
roughly **USD 30–40 / month** before LLM API costs. SQS, Scheduler, SSM and S3 are cents
at this scale. Check the AWS Pricing Calculator for your region; new accounts may get
some of this in the free tier. A budget alert emails you at 80 % / 100 % of `budget_limit_usd`.

## 1. Create the infrastructure

Prerequisites: AWS CLI logged in to your account, Terraform ≥ 1.5,
and the AWS Session Manager plugin for the CLI.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set alert_email
terraform init
terraform apply
```

Takes about 10 minutes (RDS is the slow part). Note the outputs.

## 2. Store the LLM API keys

Keys never go into Terraform state or files on the server:

```bash
aws ssm put-parameter --region eu-south-2 --type SecureString --overwrite \
  --name /geo-pilot/openai_api_key --value 'sk-...'
# repeat for anthropic, perplexity, gemini
```

## 3. Point a domain at the server

Create an A record, e.g. `geo.jilai.ai` → `public_ip` output.

## 4. Deploy the app

There is no SSH. Open a shell through Session Manager:

```bash
aws ssm start-session --region eu-south-2 --target <instance_id>
sudo su - ec2-user
cd /opt/geo
```

Put the contents of `deploy/` there (`git clone` your repo, or copy the files),
create `app.env` from `app.env.example`, then:

```bash
docker compose up -d --build
docker compose logs -f
```

`aws.env` (queue URL, bucket, DB host, secret ARN) is already written by the
first-boot script. The app reads the DB password from Secrets Manager and the API
keys from SSM using the instance role, so no credentials are needed on the server.

The compose file expects the application code in `/opt/geo/app` with a Dockerfile,
providing `geo.api:app` (FastAPI) and `geo.worker` (SQS worker).

## Worker contract

- Message `{"type": "monthly_run"}` (sent by the scheduler): enqueue one
  `{"type": "client_run", "client_id": ...}` per active client.
- Message `{"type": "client_run", ...}`: run that client's prompts, then delete the message.
- A message that fails 3 times lands in the `-dlq` queue for inspection.
- On-demand runs from the dashboard just send a `client_run` message.

## Growing later

Same code, more infrastructure: move the worker to its own Auto Scaling group that
scales on SQS depth, add an ALB + ACM certificate, private subnets with NAT, and
Cognito for per-agency login.

## Tear down

`deletion_protection` is on for the database. Set it to `false`, `terraform apply`,
then `terraform destroy` (a final DB snapshot is kept).
