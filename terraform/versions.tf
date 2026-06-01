terraform {
  required_version = ">= 1.5.0"

  # Remote state in OCI Object Storage via its S3-compatible API. Creds come from
  # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars (an OCI Customer Secret
  # Key) — never committed. See ~/.secrets/freellmapi-tfstate-s3.env.
  backend "s3" {
    bucket = "freellmapi-tfstate"
    key    = "freellmapi/terraform.tfstate"
    region = "us-ashburn-1"
    endpoints = {
      s3 = "https://id3z6oivrpp7.compat.objectstorage.us-ashburn-1.oraclecloud.com"
    }
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  region       = var.region
  # Auth resolves from the standard OCI config file (~/.oci/config) or, when run
  # inside OCI Resource Manager / on an instance, from the instance principal.
  # No keys are committed here.
}
