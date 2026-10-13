output "public_ip" {
  description = "Point your dashboard domain (A record) here"
  value       = aws_eip.app.public_ip
}

output "instance_id" {
  description = "Connect with: aws ssm start-session --target <instance_id>"
  value       = aws_instance.app.id
}

output "db_endpoint" {
  value = aws_db_instance.postgres.address
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the DB username/password"
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "bucket" {
  value = aws_s3_bucket.data.bucket
}

output "queue_url" {
  value = aws_sqs_queue.jobs.url
}

output "api_key_parameters" {
  description = "Set each real API key with: aws ssm put-parameter --name <name> --type SecureString --overwrite --value <key>"
  value       = [for p in aws_ssm_parameter.llm_api_key : p.name]
}
