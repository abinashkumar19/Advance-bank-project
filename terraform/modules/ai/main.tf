# ---------------------------------------------------------------------------
# AI/GenAI - Amazon Bedrock access for the chatbot service.
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "bedrock_app_access" {
  name        = "${var.project_name}-${var.environment}-bedrock-app-access"
  description = "Allows the chatbot pod to invoke Bedrock foundation models"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}"
        ]
      }
    ]
  })
}
