# Phase 4: keep ENCRYPTION_KEY in an OCI Vault secret; the instance reads it at
# boot via instance principal. The master key is then centralized + access-
# controlled rather than spread across tfvars/disk. Provider keys stay encrypted
# in the app's SQLite DB (the app has no Vault integration by design).

resource "oci_kms_vault" "app" {
  count          = var.enable_app_secret_vault ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "freellmapi-app-vault"
  vault_type     = "DEFAULT"
}

# Software AES key to encrypt the secret (secrets don't need an HSM key — free).
resource "oci_kms_key" "app" {
  count               = var.enable_app_secret_vault ? 1 : 0
  compartment_id      = var.compartment_ocid
  display_name        = "freellmapi-secret-key"
  management_endpoint = oci_kms_vault.app[0].management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

resource "oci_vault_secret" "encryption_key" {
  count          = var.enable_app_secret_vault ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.app[0].id
  key_id         = oci_kms_key.app[0].id
  secret_name    = "freellmapi-encryption-key"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.encryption_key)
  }
}

# Dynamic group matching the app instance, + policy to read the secret.
resource "oci_identity_dynamic_group" "instance" {
  count          = var.enable_app_secret_vault ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "freellmapi-instances"
  description    = "FreeLLMAPI app instance(s) — read the ENCRYPTION_KEY secret"
  matching_rule  = "ALL {instance.id = '${oci_core_instance.app.id}'}"
}

resource "oci_identity_policy" "instance_read_secret" {
  count          = var.enable_app_secret_vault ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = "freellmapi-instance-read-secret"
  description    = "Allow the app instance to read the ENCRYPTION_KEY secret"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.instance[0].name} to read secret-family in compartment id ${var.compartment_ocid}",
  ]
}

output "encryption_key_secret_ocid" {
  description = "OCID of the Vault secret holding ENCRYPTION_KEY (null unless enable_app_secret_vault)."
  value       = try(oci_vault_secret.encryption_key[0].id, null)
}
