#############################################################################
# DR Notifications (Route53 healthcheck -> CloudWatch Alarm -> SNS -> Email)
#############################################################################

locals {
  dr_notify_enabled = var.enable_dr_notifications && length(var.dr_notification_emails) > 0
}

# SNS topic para FAILOVER (primario caído => Route53 conmutará a secondary)
resource "aws_sns_topic" "dr_failover" {
  provider = aws.sns
  count    = local.dr_notify_enabled ? 1 : 0

  name         = "${terraform.workspace}-dr-failover"
  display_name = "DR FAILOVER - ${var.project_name} (${terraform.workspace})"

  tags = merge(local.common_tags, {
    Tier = "Alerting"
    Type = "DR-Failover"
  })
}

# SNS topic para FAILBACK (primario vuelve OK)
resource "aws_sns_topic" "dr_failback" {
  provider = aws.sns
  count    = local.dr_notify_enabled ? 1 : 0

  name         = "${terraform.workspace}-dr-failback"
  display_name = "DR FAILBACK - ${var.project_name} (${terraform.workspace})"

  tags = merge(local.common_tags, {
    Tier = "Alerting"
    Type = "DR-Failback"
  })
}

# Suscripciones email (FAILOVER)
resource "aws_sns_topic_subscription" "dr_failover_email" {
  provider = aws.sns
  for_each = local.dr_notify_enabled ? toset(var.dr_notification_emails) : toset([])

  topic_arn = aws_sns_topic.dr_failover[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# Suscripciones email (FAILBACK)
resource "aws_sns_topic_subscription" "dr_failback_email" {
  provider = aws.sns
  for_each = local.dr_notify_enabled ? toset(var.dr_notification_emails) : toset([])

  topic_arn = aws_sns_topic.dr_failback[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# CloudWatch Alarm sobre Route53 HealthCheckStatus (1=healthy, 0=unhealthy)
# Nota: el Alarm (y los SNS topics) deben estar en us-east-1
resource "aws_cloudwatch_metric_alarm" "route53_primary_unhealthy" {
  provider = aws.sns
  count    = local.dr_notify_enabled ? 1 : 0

  alarm_name        = "${terraform.workspace}-route53-primary-unhealthy"
  alarm_description = <<-EOT
  Disparador de DR: el HealthCheck de Route53 del ALB primario ha pasado a UNHEALTHY (HealthCheckStatus=0).
  Acción esperada: Route53 hará failover hacia la región secundaria (Pilot Light).
  Procedimiento: iniciar el Runbook DR Manual CLI - RDS PostgreSQL (Pilot Light).
  EOT

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"
  statistic   = "Minimum"
  period      = 60

  evaluation_periods  = 1
  datapoints_to_alarm = 1

  comparison_operator = "LessThanThreshold"
  threshold           = 1

  dimensions = {
    HealthCheckId = aws_route53_health_check.frontend_primary.id
  }

  treat_missing_data = "missing"

  actions_enabled = true

  # FAILOVER: cuando pasa a ALARM
  alarm_actions = [
    aws_sns_topic.dr_failover[0].arn
  ]

  # FAILBACK: cuando vuelve a OK
  ok_actions = [
    aws_sns_topic.dr_failback[0].arn
  ]

  # (Opcional) Notificar también si hay datos insuficientes
  insufficient_data_actions = [
    aws_sns_topic.dr_failover[0].arn
  ]

  tags = merge(local.common_tags, {
    Tier = "Alerting"
    Type = "CloudWatch-Alarm"
  })
}
