terraform {
  required_version = ">= 1.7.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
  }
}

provider "oci" {
  region              = var.region
  config_file_profile = var.oci_config_file_profile
}

provider "oci" {
  alias               = "home"
  region              = var.home_region
  config_file_profile = var.oci_config_file_profile
}
