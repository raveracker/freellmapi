#!/usr/bin/env bash
# Certbot DEPLOY hook: on each successful Let's-Encrypt renewal, push the new leaf
# + chain into the OCI Certificates-service certificate that the load balancer's
# HTTPS listener references (terraform var.tls_server_certificate_id).
#
# The cert OCID is STABLE — we only add a new VERSION, so the LB listener never
# changes (no Terraform drift). The instance's dynamic group has
# `manage leaf-certificate-family` (terraform/vault.tf), so this authenticates via
# instance principal — no API keys live on the box.
#
# ---- Install on the instance (run as root, through the Bastion session) ------
#   sudo install -m 0755 oci-lb-cert-deploy-hook.sh \
#        /etc/letsencrypt/renewal-hooks/deploy/oci-lb-cert.sh
#   # bake in the cert OCID (from `grep tls_server_certificate_id terraform.tfvars`):
#   echo 'OCI_LB_CERT_OCID=ocid1.certificate.oc1...' | sudo tee /etc/default/oci-lb-cert
#   # one-time dry run against the live cert:
#   sudo RENEWED_LINEAGE=/etc/letsencrypt/live/freeai.punkadillo.com \
#        /etc/letsencrypt/renewal-hooks/deploy/oci-lb-cert.sh
#
# Certbot sets RENEWED_LINEAGE automatically on real renewals; the env file and
# the DOMAIN fallback below cover manual invocation.
set -euo pipefail

[ -f /etc/default/oci-lb-cert ] && . /etc/default/oci-lb-cert

CERT_OCID="${OCI_LB_CERT_OCID:?set OCI_LB_CERT_OCID (var.tls_server_certificate_id) in /etc/default/oci-lb-cert}"
DOMAIN="${DOMAIN:-freeai.punkadillo.com}"
LINEAGE="${RENEWED_LINEAGE:-/etc/letsencrypt/live/$DOMAIN}"
OCI_BIN="$(command -v oci || echo /root/bin/oci)"

# LE lineage: cert.pem = leaf, chain.pem = intermediates, privkey.pem = key.
# OCI wants the leaf and the chain separately (NOT fullchain).
"$OCI_BIN" certs-mgmt certificate update-certificate-by-importing-config-details \
  --auth instance_principal \
  --certificate-id "$CERT_OCID" \
  --certificate-pem "$(cat "$LINEAGE/cert.pem")" \
  --cert-chain-pem  "$(cat "$LINEAGE/chain.pem")" \
  --private-key-pem "$(cat "$LINEAGE/privkey.pem")" \
  --wait-for-state ACTIVE

logger -t oci-lb-cert "pushed renewed $DOMAIN cert version to $CERT_OCID"
echo "OK: new version imported for $CERT_OCID — verify it is CURRENT in the console;"
echo "    the LB listener picks up the current version automatically (no LB change)."
