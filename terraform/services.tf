# Single source of truth for the microservices in this project.
# accounts, transactions, users, and transfers have custom schemas
# (defined explicitly in dynamodb.tf, since transfers needs GSIs to look
# up a transfer by either the sending or receiving account); everything
# in `generic_services` gets a simple id-keyed table generated via
# for_each.
locals {
  # Every service that maps 1:1 to a backend/services/<name> folder with
  # its own Dockerfile - this list drives ECR repos AND the CI Docker
  # build loop (.github/workflows/deploy.yml), so every entry here MUST
  # have a matching folder or the build fails with "no such file or
  # directory".
  generic_services = [
    "cards", "loans", "payments", "beneficiaries",
    "statements", "notifications", "kyc", "fixed-deposits", "cheques",
    "disputes", "audit-log", "fraud-detection", "support-tickets",
    "rewards", "admin", "reports",
    "recurring-payments", "bill-payments", "insurance", "budgeting",
    "virtual-cards", "goals", "webhooks",
    "lockers", "forex",
  ]

  # Every DynamoDB table generated via the generic for_each in
  # modules/dynamodb. Almost identical to generic_services, but also
  # includes tables that don't have their own service/Dockerfile -
  # webhook-deliveries is a second table the webhooks service writes to
  # (delivery log), not a separate running service. Anything added here
  # that ISN'T also in generic_services must not be added to
  # generic_services/backend_services, or the Docker build loop breaks
  # looking for a folder that was never meant to exist.
  generic_tables = concat(local.generic_services, ["webhook-deliveries"])

  # Every backend microservice (used for ECR repos + IRSA policy).
  # chatbot is stateless (just calls the Groq API, no DynamoDB table of its
  # own) so it's listed directly here rather than in generic_services.
  # admin-analytics is also stateless in the same sense (reads other
  # services' tables, has none of its own) but still needs an ECR
  # repo/deployment since it's a real running service.
  backend_services = concat(["accounts", "transactions", "users", "transfers", "chatbot", "admin-analytics"], local.generic_services)

  # Everything that gets its own ECR repo, including the frontend.
  all_images = concat(local.backend_services, ["frontend"])

  # Subset of generic_tables that also gets a user_id-index GSI (so a user
  # can list "my cards", "my loans", etc. via a Query instead of a table
  # Scan). audit-log, fraud-detection, admin, statements, and reports are
  # staff-facing/bank-wide views instead, so they don't get this GSI.
  user_indexed_generic_tables = toset([
    "cards", "loans", "payments", "beneficiaries", "kyc",
    "fixed-deposits", "cheques", "disputes", "support-tickets",
    "rewards", "notifications",
    "recurring-payments", "bill-payments", "insurance", "budgeting",
    "virtual-cards", "goals", "webhooks", "webhook-deliveries",
    "lockers", "forex",
  ])
}
