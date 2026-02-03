#############################################################################
#################### DB DR Automation (Lambda + EventBridge) ################
#############################################################################

data "archive_file" "db_dr_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.root}/lambda/db_dr"
  output_path = "${path.root}/db_dr.zip"
}

# Estado en SSM (la Lambda lo va actualizando)
resource "aws_ssm_parameter" "db_dr_state" {
  provider = aws.secondary

  name = "/pilotlight/${terraform.workspace}/db/state"
  type = "String"
  value = jsonencode({
    active            = "primary"
    phase             = "steady"
    primary_writer_id = module.db_primary.db_instance_id
    ts                = "init"
  })

  tags = merge(local.common_tags, local.secondary_tags, { Tier = "DR-State" })

  lifecycle {
    ignore_changes = [value]
  }
}

# IAM role Lambda
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "db_dr_lambda_role" {
  provider           = aws.secondary
  name               = "${terraform.workspace}-db-dr-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = merge(local.common_tags, local.secondary_tags, { Tier = "IAM" })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  provider   = aws.secondary
  role       = aws_iam_role.db_dr_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "db_dr_lambda_policy" {
  provider = aws.secondary
  name     = "${terraform.workspace}-db-dr-lambda-policy"
  role     = aws_iam_role.db_dr_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # RDS actions (ambas regiones)
      {
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:PromoteReadReplica",
          "rds:CreateDBInstanceReadReplica",
          "rds:DeleteDBInstance"
        ]
        Resource = "*"
      },

      # Route53 UPSERT record (DB private zone)
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${aws_route53_zone.db_private.zone_id}"
      },

      # Route53 health check status (trigger DR)
      {
        Effect = "Allow"
        Action = [
          "route53:GetHealthCheckStatus"
        ]
        Resource = "arn:aws:route53:::healthcheck/${aws_route53_health_check.frontend_primary.id}"
      },

      # SSM state (en región secundaria)
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = aws_ssm_parameter.db_dr_state.arn
      }
    ]
  })
}

resource "aws_lambda_function" "db_dr" {
  provider = aws.secondary

  function_name = "${terraform.workspace}-db-dr-automation"
  role          = aws_iam_role.db_dr_lambda_role.arn

  runtime = "python3.12"
  handler = "lambda_function.handler"

  filename         = data.archive_file.db_dr_lambda_zip.output_path
  source_code_hash = data.archive_file.db_dr_lambda_zip.output_base64sha256

  timeout = 60

  environment {
    variables = {
      PRIMARY_REGION   = var.primary_region
      SECONDARY_REGION = var.secondary_region

      PRIMARY_DB_ID   = module.db_primary.db_instance_id
      SECONDARY_DB_ID = module.db_secondary.db_instance_id

      FAILBACK_DB_ID = "${terraform.workspace}-rds-primary-failback"

      PRIMARY_KMS_KEY   = aws_kms_key.rds_primary.arn
      SECONDARY_KMS_KEY = aws_kms_key.rds_secondary.arn

      PRIMARY_SUBNET_GROUP   = "${terraform.workspace}-rds-primary-subnets"
      SECONDARY_SUBNET_GROUP = "${terraform.workspace}-rds-secondary-subnets"

      PRIMARY_DB_SG_ID   = module.network_primary.db_sg_id
      SECONDARY_DB_SG_ID = module.network_secondary.db_sg_id

      PRIMARY_CLASS   = var.db_instance_class_primary
      SECONDARY_CLASS = var.db_instance_class_secondary

      ROUTE53_ZONE_ID         = aws_route53_zone.db_private.zone_id
      ROUTE53_RECORD_NAME     = "${var.db_record_name}.${var.db_private_zone_name}"
      ROUTE53_HEALTH_CHECK_ID = aws_route53_health_check.frontend_primary.id

      STATE_PARAM_NAME = aws_ssm_parameter.db_dr_state.name
      TTL              = "30"
    }
  }

  depends_on = [
    aws_route53_zone_association.db_private_secondary
  ]

  tags = merge(local.common_tags, local.secondary_tags, { Tier = "Lambda" })
}

# Schedule: cada 1 minuto
resource "aws_cloudwatch_event_rule" "db_dr_schedule" {
  provider = aws.secondary

  name                = "${terraform.workspace}-db-dr-schedule"
  schedule_expression = var.enable_db_dr_automation ? "rate(1 minute)" : "rate(365 days)"

  tags = merge(local.common_tags, local.secondary_tags, { Tier = "EventBridge" })
}

resource "aws_cloudwatch_event_target" "db_dr_target" {
  provider = aws.secondary

  rule = aws_cloudwatch_event_rule.db_dr_schedule.name
  arn  = aws_lambda_function.db_dr.arn
}

resource "aws_lambda_permission" "allow_events" {
  provider = aws.secondary

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.db_dr.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.db_dr_schedule.arn
}
