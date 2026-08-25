variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "dynamodb_billing_mode" {
  type = string
}

variable "generic_tables" {
  description = "Simple id-keyed tables that get a generic table via for_each - not all of these correspond 1:1 to a backend microservice (e.g. webhook-deliveries is a second table owned by the webhooks service, not its own service)"
  type        = list(string)
}

variable "user_indexed_generic_tables" {
  description = "Subset of generic_tables that also gets a user_id-index GSI"
  type        = set(string)
}
