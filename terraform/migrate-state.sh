#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time state migration: flat root resources -> child modules.
#
# Run this ONCE, from the terraform/ directory, BEFORE your next
# `terraform apply`. It rewrites resource addresses in your remote state
# to match the new module structure, so Terraform sees "this already
# exists, just tracked under a new address" instead of "this doesn't
# exist, create it" (which would try to destroy + recreate everything,
# including your RDS cluster and EKS cluster).
#
# Safe to re-run: every move is wrapped so a resource that's already been
# moved, or was never created in the first place (e.g. the OpenSearch
# domain / CloudWatch addon that failed on your last apply), is skipped
# with a note instead of aborting the whole script.
#
# After this finishes, run `terraform plan` - it should show few or no
# changes (aside from genuinely new resources like the OpenSearch
# service-linked role, which never got created due to the earlier error).
# ---------------------------------------------------------------------------
set -uo pipefail

moved=0
skipped=0

mv_resource() {
  local from="$1"
  local to="$2"
  if terraform state mv "$from" "$to" >/tmp/tfmv.log 2>&1; then
    echo "  moved:  $from -> $to"
    moved=$((moved+1))
  else
    echo "  skip:   $from (not in state)"
    skipped=$((skipped+1))
  fi
}

echo "== VPC =="
mv_resource 'module.vpc[0]' 'module.vpc.module.vpc[0]'

echo "== DynamoDB =="
mv_resource 'aws_dynamodb_table.accounts'          'module.dynamodb.aws_dynamodb_table.accounts'
mv_resource 'aws_dynamodb_table.transfers'         'module.dynamodb.aws_dynamodb_table.transfers'
mv_resource 'aws_dynamodb_table.users'             'module.dynamodb.aws_dynamodb_table.users'
mv_resource 'aws_dynamodb_table.otp_codes'         'module.dynamodb.aws_dynamodb_table.otp_codes'
mv_resource 'aws_iam_policy.dynamodb_app_access'   'module.dynamodb.aws_iam_policy.dynamodb_app_access'

generic_services=(cards loans payments beneficiaries statements notifications kyc fixed-deposits cheques disputes audit-log fraud-detection support-tickets rewards admin reports)
for svc in "${generic_services[@]}"; do
  mv_resource "aws_dynamodb_table.generic[\"$svc\"]" "module.dynamodb.aws_dynamodb_table.generic[\"$svc\"]"
done

echo "== RDS =="
mv_resource 'random_password.db_master'                                          'module.rds.random_password.db_master'
mv_resource 'aws_db_subnet_group.users'                                          'module.rds.aws_db_subnet_group.users'
mv_resource 'aws_security_group.users_db_sync_lambda'                            'module.rds.aws_security_group.users_db_sync_lambda'
mv_resource 'aws_security_group.users_db'                                        'module.rds.aws_security_group.users_db'
mv_resource 'aws_rds_cluster.users'                                              'module.rds.aws_rds_cluster.users'
mv_resource 'aws_rds_cluster_instance.writer'                                    'module.rds.aws_rds_cluster_instance.writer'
mv_resource 'aws_rds_cluster_instance.reader'                                    'module.rds.aws_rds_cluster_instance.reader'
mv_resource 'aws_s3_bucket.users_db_creds'                                       'module.rds.aws_s3_bucket.users_db_creds'
mv_resource 'aws_s3_bucket_versioning.users_db_creds'                            'module.rds.aws_s3_bucket_versioning.users_db_creds'
mv_resource 'aws_s3_bucket_server_side_encryption_configuration.users_db_creds'  'module.rds.aws_s3_bucket_server_side_encryption_configuration.users_db_creds'
mv_resource 'aws_s3_bucket_public_access_block.users_db_creds'                   'module.rds.aws_s3_bucket_public_access_block.users_db_creds'
mv_resource 'aws_s3_object.users_db_creds'                                       'module.rds.aws_s3_object.users_db_creds'
mv_resource 'aws_iam_policy.users_db_secret_access'                              'module.rds.aws_iam_policy.users_db_secret_access'

echo "== S3 (transaction history) =="
mv_resource 'aws_s3_bucket.transaction_history'                                      'module.s3.aws_s3_bucket.transaction_history'
mv_resource 'aws_s3_bucket_versioning.transaction_history'                           'module.s3.aws_s3_bucket_versioning.transaction_history'
mv_resource 'aws_s3_bucket_server_side_encryption_configuration.transaction_history' 'module.s3.aws_s3_bucket_server_side_encryption_configuration.transaction_history'
mv_resource 'aws_s3_bucket_public_access_block.transaction_history'                  'module.s3.aws_s3_bucket_public_access_block.transaction_history'

echo "== ECR =="
generic_services_for_ecr=(cards loans payments beneficiaries statements notifications kyc fixed-deposits cheques disputes audit-log fraud-detection support-tickets rewards admin reports)
all_images=(accounts transactions users transfers chatbot "${generic_services_for_ecr[@]}" frontend)
for img in "${all_images[@]}"; do
  mv_resource "aws_ecr_repository.service[\"$img\"]"        "module.ecr.aws_ecr_repository.service[\"$img\"]"
  mv_resource "aws_ecr_lifecycle_policy.service[\"$img\"]"  "module.ecr.aws_ecr_lifecycle_policy.service[\"$img\"]"
done

echo "== SNS =="
mv_resource 'aws_sns_topic.user_registered'                    'module.sns.aws_sns_topic.user_registered'
mv_resource 'aws_iam_policy.sns_publish_user_registered'       'module.sns.aws_iam_policy.sns_publish_user_registered'
mv_resource 'aws_sns_topic_subscription.user_registered_email[0]' 'module.sns.aws_sns_topic_subscription.user_registered_email[0]'
mv_resource 'aws_sqs_queue.user_registered_notifications'      'module.sns.aws_sqs_queue.user_registered_notifications'
mv_resource 'aws_sqs_queue_policy.user_registered_notifications' 'module.sns.aws_sqs_queue_policy.user_registered_notifications'
mv_resource 'aws_sns_topic_subscription.user_registered_sqs'   'module.sns.aws_sns_topic_subscription.user_registered_sqs'

echo "== SES =="
mv_resource 'aws_ses_email_identity.sender[0]' 'module.ses.aws_ses_email_identity.sender[0]'

echo "== Lambda: transactions-history =="
mv_resource 'aws_iam_role.transactions_history_lambda'         'module.lambda.aws_iam_role.transactions_history_lambda'
mv_resource 'aws_iam_role_policy.transactions_history_lambda'  'module.lambda.aws_iam_role_policy.transactions_history_lambda'
mv_resource 'aws_lambda_function.transactions_history'         'module.lambda.aws_lambda_function.transactions_history'
mv_resource 'aws_apigatewayv2_api.transactions_history'        'module.lambda.aws_apigatewayv2_api.transactions_history'
mv_resource 'aws_apigatewayv2_integration.transactions_history' 'module.lambda.aws_apigatewayv2_integration.transactions_history'
mv_resource 'aws_apigatewayv2_route.write_history'             'module.lambda.aws_apigatewayv2_route.write_history'
mv_resource 'aws_apigatewayv2_route.read_history'               'module.lambda.aws_apigatewayv2_route.read_history'
mv_resource 'aws_apigatewayv2_stage.transactions_history'      'module.lambda.aws_apigatewayv2_stage.transactions_history'
mv_resource 'aws_lambda_permission.transactions_history_apigw' 'module.lambda.aws_lambda_permission.transactions_history_apigw'

echo "== Lambda: users-db-sync =="
mv_resource 'null_resource.users_db_sync_deps'                          'module.lambda.null_resource.users_db_sync_deps'
mv_resource 'aws_iam_role.users_db_sync_lambda'                         'module.lambda.aws_iam_role.users_db_sync_lambda'
mv_resource 'aws_iam_role_policy_attachment.users_db_sync_lambda_vpc'   'module.lambda.aws_iam_role_policy_attachment.users_db_sync_lambda_vpc'
mv_resource 'aws_iam_role_policy_attachment.users_db_sync_lambda_db_creds' 'module.lambda.aws_iam_role_policy_attachment.users_db_sync_lambda_db_creds'
mv_resource 'aws_iam_role_policy.users_db_sync_lambda_stream'           'module.lambda.aws_iam_role_policy.users_db_sync_lambda_stream'
mv_resource 'aws_lambda_function.users_db_sync'                         'module.lambda.aws_lambda_function.users_db_sync'
mv_resource 'aws_lambda_event_source_mapping.users_db_sync'             'module.lambda.aws_lambda_event_source_mapping.users_db_sync'

echo "== Lambda: notification-writer =="
mv_resource 'aws_iam_role.notification_writer_lambda'          'module.lambda.aws_iam_role.notification_writer_lambda'
mv_resource 'aws_iam_role_policy.notification_writer_lambda'   'module.lambda.aws_iam_role_policy.notification_writer_lambda'
mv_resource 'aws_lambda_function.notification_writer'          'module.lambda.aws_lambda_function.notification_writer'
mv_resource 'aws_lambda_event_source_mapping.notification_writer_sqs' 'module.lambda.aws_lambda_event_source_mapping.notification_writer_sqs'

echo "== EKS =="
mv_resource 'module.eks'                              'module.eks.module.eks'
mv_resource 'module.ebs_csi_irsa'                      'module.eks.module.ebs_csi_irsa'
mv_resource 'aws_eks_addon.ebs_csi'                    'module.eks.aws_eks_addon.ebs_csi'
mv_resource 'module.alb_controller_irsa'               'module.eks.module.alb_controller_irsa'
mv_resource 'kubernetes_service_account.alb_controller' 'module.eks.kubernetes_service_account.alb_controller'
mv_resource 'helm_release.alb_controller'              'module.eks.helm_release.alb_controller'

echo "== Backend IRSA (was directly under eks.tf, now its own module) =="
mv_resource 'module.backend_app_irsa' 'module.backend_irsa.module.backend_app_irsa'

echo "== Observability (may not exist yet - your last apply failed here) =="
mv_resource 'aws_eks_addon.cloudwatch_observability' 'module.observability.aws_eks_addon.cloudwatch_observability'
mv_resource 'aws_cloudwatch_log_group.app'           'module.observability.aws_cloudwatch_log_group.app'
mv_resource 'aws_iam_policy.xray_write_access'       'module.observability.aws_iam_policy.xray_write_access'
mv_resource 'module.xray_irsa'                       'module.observability.module.xray_irsa'

echo "== Messaging =="
mv_resource 'aws_sqs_queue.dlq'                                    'module.messaging.aws_sqs_queue.dlq'
mv_resource 'aws_sqs_queue.fraud_check'                             'module.messaging.aws_sqs_queue.fraud_check'
mv_resource 'aws_sqs_queue.doc_generation'                          'module.messaging.aws_sqs_queue.doc_generation'
mv_resource 'aws_cloudwatch_event_bus.app'                          'module.messaging.aws_cloudwatch_event_bus.app'
mv_resource 'aws_cloudwatch_event_rule.transaction_completed'       'module.messaging.aws_cloudwatch_event_rule.transaction_completed'
mv_resource 'aws_cloudwatch_event_target.transaction_completed_to_fraud_check' 'module.messaging.aws_cloudwatch_event_target.transaction_completed_to_fraud_check'
mv_resource 'aws_sqs_queue_policy.fraud_check_allow_eventbridge'    'module.messaging.aws_sqs_queue_policy.fraud_check_allow_eventbridge'
mv_resource 'aws_iam_policy.messaging_app_access'                   'module.messaging.aws_iam_policy.messaging_app_access'

echo "== Search (may partially not exist - your last apply failed on the OpenSearch domain) =="
mv_resource 'aws_iam_service_linked_role.opensearch' 'module.search.aws_iam_service_linked_role.opensearch'
mv_resource 'aws_security_group.search_and_cache'    'module.search.aws_security_group.search_and_cache'
mv_resource 'aws_opensearch_domain.app'              'module.search.aws_opensearch_domain.app'
mv_resource 'random_password.opensearch_master'      'module.search.random_password.opensearch_master'
mv_resource 'aws_elasticache_subnet_group.app'       'module.search.aws_elasticache_subnet_group.app'
mv_resource 'aws_elasticache_cluster.app'            'module.search.aws_elasticache_cluster.app'
mv_resource 'aws_iam_policy.search_cache_app_access' 'module.search.aws_iam_policy.search_cache_app_access'

echo "== Networking =="
mv_resource 'aws_acm_certificate.app[0]' 'module.networking.aws_acm_certificate.app[0]'
mv_resource 'aws_vpc_endpoint.s3'        'module.networking.aws_vpc_endpoint.s3'
mv_resource 'aws_vpc_endpoint.dynamodb'  'module.networking.aws_vpc_endpoint.dynamodb'

echo "== AI =="
mv_resource 'aws_iam_policy.bedrock_app_access' 'module.ai.aws_iam_policy.bedrock_app_access'

echo ""
echo "== New in this pass: scoring, security, analytics, monitoring =="
echo "  These are brand-new modules with nothing to migrate - terraform"
echo "  apply will just create them fresh."

echo ""
echo "Done. Moved: $moved   Skipped (not in state): $skipped"
echo "Now run: terraform plan"
echo "It should show mostly no changes, plus a few genuinely-new resources"
echo "(e.g. the OpenSearch service-linked role / domain, if they never"
echo "actually got created due to the earlier apply error)."
