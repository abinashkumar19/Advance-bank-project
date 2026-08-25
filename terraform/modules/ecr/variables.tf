variable "project_name" {
  type = string
}

variable "all_images" {
  description = "Every service (+ frontend) that gets its own ECR repo"
  type        = list(string)
}
