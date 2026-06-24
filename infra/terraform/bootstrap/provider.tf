# Bootstrap config: creates the Object Storage bucket the ROOT module uses for remote state.
# Run ONCE, with LOCAL state (this dir's *.tfstate is gitignored and disposable — the bucket
# it creates is trivially recreatable). Auth is the same API key as the root (see
# notes/oracle-cloud-setup.md §3). See README.md for the run order.
provider "oci" {
  config_file_profile = var.oci_config_profile
  region              = var.region
}

variable "oci_config_profile" {
  description = "Profile name in ~/.oci/config to use for API-key auth."
  type        = string
  default     = "DEFAULT"
}

variable "region" {
  description = "OCI region identifier (e.g. uk-london-1)."
  type        = string
}
