variable "name" {
  description = "Prefix used for all resource names"
  type        = string
  default     = "geo-pilot"
}

variable "region" {
  description = "AWS region. eu-south-2 = Spain (Madrid)."
  type        = string
  default     = "eu-south-2"
}

variable "instance_type" {
  description = "EC2 type for the single app + worker server (ARM/Graviton)"
  type        = string
  default     = "t4g.small"
}

variable "db_instance_class" {
  description = "RDS PostgreSQL instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_storage_gb" {
  description = "RDS storage in GB"
  type        = number
  default     = 20
}

variable "monthly_run_cron" {
  description = "When the monthly GEO run starts (EventBridge Scheduler cron, in schedule_timezone)"
  type        = string
  default     = "cron(0 6 1 * ? *)" # 06:00 on the 1st of every month
}

variable "schedule_timezone" {
  description = "Time zone for the schedule"
  type        = string
  default     = "Europe/Madrid"
}

variable "budget_limit_usd" {
  description = "Monthly AWS budget; you get an email at 80% and 100%"
  type        = number
  default     = 60
}

variable "alert_email" {
  description = "Email for budget alerts"
  type        = string
}

variable "llm_providers" {
  description = "One SSM SecureString parameter is created per provider for its API key"
  type        = list(string)
  default     = ["openai", "anthropic", "perplexity", "gemini"]
}
