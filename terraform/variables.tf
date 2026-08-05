variable "tenancy_ocid" { type = string }
variable "compartment_ocid" { type = string }
variable "region" { type = string }
variable "home_region" {
  type        = string
  default     = "us-ashburn-1"
  description = "OCI tenancy home region; Identity create/update/delete operations run here."
}
variable "availability_domain" { type = string }
variable "compute_image_ocid" { type = string }
variable "ssh_public_key" { type = string }
variable "bastion_client_cidr" {
  type        = string
  description = "Your current public IPv4 address in /32 notation."
  validation {
    condition     = can(cidrhost(var.bastion_client_cidr, 0)) && endswith(var.bastion_client_cidr, "/32")
    error_message = "bastion_client_cidr must be one IPv4 /32 address."
  }
}
variable "genai_project_ocid" { type = string }
variable "genai_model_id" {
  type        = string
  description = "Exact enabled OCI on-demand model ID with chat-completions tool-calling support."
}
variable "instance_shape" {
  type    = string
  default = "VM.Standard.E5.Flex"
}
variable "instance_ocpus" {
  type    = number
  default = 2
}
variable "instance_memory_gbs" {
  type    = number
  default = 16
}
variable "boot_volume_size_gbs" {
  type    = number
  default = 100
}
variable "name_prefix" {
  type    = string
  default = "hermes"
}
