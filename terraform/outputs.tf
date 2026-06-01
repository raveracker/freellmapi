output "load_balancer_public_ip" {
  description = "Public IP of the LB. Point freeai.punkadillo.com (A record) at this."
  value       = try(oci_load_balancer_load_balancer.lb.ip_address_details[0].ip_address, null)
}

output "instance_private_ip" {
  description = "Private IP of the A1 instance (reachable only via Bastion / the LB)."
  value       = oci_core_instance.app.private_ip
}

output "instance_ocid" {
  description = "OCID of the A1 instance — use it for the Bastion session and the Phase 4 dynamic group."
  value       = oci_core_instance.app.id
}

output "vcn_ocid" {
  value = oci_core_vcn.vcn.id
}

output "ca_ocid" {
  description = "Private Root CA OCID — UNUSED private-CA fallback (null unless enable_private_ca = true). The live server cert is Let's Encrypt, not this."
  value       = try(oci_certificates_management_certificate_authority.root[0].id, null)
}

output "certificate_ocid" {
  description = "Private-CA leaf cert OCID — UNUSED fallback (null unless enable_private_ca = true). The live LB cert is the imported LE cert in var.tls_server_certificate_id."
  value       = try(oci_certificates_management_certificate.leaf[0].id, null)
}

# PRIVATE-CA FALLBACK ONLY (enable_private_ca = true). The live server cert is a
# publicly-trusted Let's Encrypt cert, so clients need NO CA bundle for the server
# side; access is gated by mTLS (a client cert) on 443 and/or the bearer token.
output "ca_bundle_fetch_cmd" {
  description = "Private-CA fallback: command to export the CA bundle clients would trust IF using the private CA. Not needed with the live LE cert."
  value = try(
    "oci certificates certificate-authority-bundle get --certificate-authority-id ${oci_certificates_management_certificate_authority.root[0].id} --query 'data.\"certificate-pem\"' --raw-output > ca-bundle.pem",
    "(private CA disabled — live cert is publicly-trusted Let's Encrypt; no CA bundle needed)"
  )
}

output "notifications_topic_ocid" {
  description = "ONS topic for alarms (null unless enable_observability = true)."
  value       = try(oci_ons_notification_topic.alerts[0].id, null)
}

output "observability_reminder" {
  description = "Manual step Terraform can't do for you."
  value       = var.enable_observability ? "Check ${var.alert_email} and CLICK the OCI subscription-confirmation link — an unconfirmed email subscription receives nothing." : "(observability disabled)"
}

output "next_steps" {
  value = <<-EOT
    DNS: A record  ${var.domain_name} -> ${try(oci_load_balancer_load_balancer.lb.ip_address_details[0].ip_address, "<lb-ip>")}

    TLS is live: a publicly-trusted Let's Encrypt server cert (imported into the
    Certificates service, var.tls_server_certificate_id) terminates on the LB.
    Renewal is certbot + a deploy-hook that re-imports the new version (stable OCID).

    Access paths (both also require the app bearer token):
      - 443 : mTLS — clients must present a cert signed by the private client CA.
              curl --cert client.pem --key client.key https://${var.domain_name}/v1/models
              (a request with no client cert gets HTTP 400 from the LB — expected.)
      - ${var.bearer_listener_port}: bearer-only, no client cert${var.enable_bearer_listener ? "" : " (set enable_bearer_listener = true)"}.
              For clients that can't do mTLS, e.g. Cursor's custom OpenAI base URL:
              https://${var.domain_name}:${var.bearer_listener_port}/v1

    SSH for debugging via OCI Bastion -> instance OCID ${oci_core_instance.app.id}.
  EOT
}
