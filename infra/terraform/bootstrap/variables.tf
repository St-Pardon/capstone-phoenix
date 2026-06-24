variable "compartment_ocid" {
  description = "OCID of the compartment that will hold the Terraform state bucket."
  type        = string
}

variable "state_bucket_name" {
  description = "Name of the Object Storage bucket for remote Terraform state."
  type        = string
  default     = "phoenix-tfstate"
}
