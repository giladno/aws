# CloudWatch Events (EventBridge) Scheduled Trigger
resource "aws_cloudwatch_event_rule" "schedule" {
  count = var.function_config.triggers.schedule != null && var.function_config.triggers.schedule.enabled ? 1 : 0

  name                = "${var.config.name}-${var.function_name}-schedule"
  description         = var.function_config.triggers.schedule.description
  schedule_expression = var.function_config.triggers.schedule.schedule_expression

  tags = var.config.common_tags
}

resource "aws_cloudwatch_event_target" "schedule" {
  count = var.function_config.triggers.schedule != null && var.function_config.triggers.schedule.enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.schedule[0].name
  target_id = "${var.function_name}Target"
  arn       = aws_lambda_function.main.arn

  # Optional input for the Lambda function
  dynamic "input_transformer" {
    for_each = var.function_config.triggers.schedule.input != null ? [1] : []
    content {
      input_template = var.function_config.triggers.schedule.input
    }
  }
}

resource "aws_lambda_permission" "allow_eventbridge" {
  count = var.function_config.triggers.schedule != null && var.function_config.triggers.schedule.enabled ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule[0].arn
}

# SQS Queue and Dead Letter Queue
resource "aws_sqs_queue" "dlq" {
  count = var.function_config.triggers.sqs != null && var.function_config.triggers.sqs.enabled && var.function_config.triggers.sqs.queue_config.enable_dlq ? 1 : 0

  name                      = "${var.config.name}-${var.function_name}-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = var.config.common_tags
}

resource "aws_sqs_queue" "main" {
  count = var.function_config.triggers.sqs != null && var.function_config.triggers.sqs.enabled ? 1 : 0

  name                       = var.function_config.triggers.sqs.queue_name != null ? var.function_config.triggers.sqs.queue_name : "${var.config.name}-${var.function_name}-queue"
  visibility_timeout_seconds = var.function_config.triggers.sqs.queue_config.visibility_timeout_seconds
  message_retention_seconds  = var.function_config.triggers.sqs.queue_config.message_retention_seconds
  delay_seconds              = var.function_config.triggers.sqs.queue_config.delay_seconds
  receive_wait_time_seconds  = var.function_config.triggers.sqs.queue_config.receive_wait_time_seconds

  # Dead letter queue configuration
  redrive_policy = var.function_config.triggers.sqs.queue_config.enable_dlq ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[0].arn
    maxReceiveCount     = var.function_config.triggers.sqs.queue_config.max_receive_count
  }) : null

  tags = var.config.common_tags
}

# SQS Event Source Mapping
resource "aws_lambda_event_source_mapping" "sqs" {
  count = var.function_config.triggers.sqs != null && var.function_config.triggers.sqs.enabled ? 1 : 0

  event_source_arn                   = aws_sqs_queue.main[0].arn
  function_name                      = aws_lambda_function.main.arn
  batch_size                         = var.function_config.triggers.sqs.batch_size
  maximum_batching_window_in_seconds = var.function_config.triggers.sqs.maximum_batching_window
}

# S3 Trigger
resource "aws_lambda_permission" "allow_s3" {
  count = var.function_config.triggers.s3 != null && var.function_config.triggers.s3.enabled ? 1 : 0

  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = "arn:aws:s3:::${local.s3_bucket_name}"
}

locals {
  # Always use the main S3 bucket
  s3_bucket_name = var.config.s3_bucket_name != null ? var.config.s3_bucket_name : ""
}

# S3 bucket notification is handled in the main S3 configuration
# This is because S3 bucket notifications must be managed centrally per bucket
