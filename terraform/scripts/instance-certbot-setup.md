# Move Let's-Encrypt renewal onto the A1 instance (Bastion handoff, Option 2)

This finishes the handoff: today renewal runs on a Mac (a `launchd` job → certbot
in `~/le-certbot/venv` → DNS-01 via Cloudflare → an OCI deploy-hook). These steps
reproduce that on the always-on private instance so the Mac is no longer load-
bearing.

**Why it's clean here:** the cert uses a **DNS-01 (Cloudflare)** challenge, which
needs no inbound connectivity — a private instance renews fine. The only secret to
relocate is the Cloudflare API token.

## Prerequisites (on your Mac)

- `enable_bastion_ssh = true` applied (creates the `app_ssh_bastion` NSG rule).
- An open session: `SSH_PUB=~/.ssh/id_ed25519.pub ./bastion-session.sh`, then in a
  second terminal `ssh -i <key> -p 2222 ubuntu@localhost`.
- Copy the Cloudflare token across (it currently lives at
  `~/.secrets/certbot-cloudflare.ini`, 600). Through the tunnel:
  ```bash
  scp -P 2222 ~/.secrets/certbot-cloudflare.ini ubuntu@localhost:/tmp/cf.ini
  ```

## On the instance (run as root)

```bash
# 1. certbot + the Cloudflare DNS plugin (self-contained venv, mirrors the Mac).
sudo apt-get update
sudo apt-get install -y python3-venv
sudo python3 -m venv /opt/le-certbot/venv
sudo /opt/le-certbot/venv/bin/pip install --upgrade pip certbot certbot-dns-cloudflare

# 2. Cloudflare credentials (root-only).
sudo install -d -m 0700 /root/.secrets
sudo install -m 0600 /tmp/cf.ini /root/.secrets/certbot-cloudflare.ini && rm -f /tmp/cf.ini

# 3. Bake the cert OCID for the deploy hook (same value as
#    terraform var.tls_server_certificate_id — region iad / Ashburn).
echo 'OCI_LB_CERT_OCID=ocid1.certificate.oc1.iad.amaaaaaasc6gsvia677ylbs342vsvpakkr3sw72qrbspmbznoahrrg7nrqwq' \
  | sudo tee /etc/default/oci-lb-cert

# 4. Install the instance-principal deploy hook (copied up via scp, or pasted).
sudo install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
sudo install -m 0755 oci-lb-cert-deploy-hook.sh \
  /etc/letsencrypt/renewal-hooks/deploy/oci-lb-cert.sh

# 5. Issue once on the instance. DNS-01 → no inbound needed. ECDSA to match.
sudo /opt/le-certbot/venv/bin/certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/certbot-cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 \
  --key-type ecdsa \
  -d freeai.punkadillo.com \
  --non-interactive --agree-tos -m <your-acme-email>

# 6. Verify the deploy hook can push a new version via instance principal
#    (no ~/.oci/config on the box — this is what the leaf-certificate-family
#    grant in terraform/vault.tf authorizes).
sudo RENEWED_LINEAGE=/etc/letsencrypt/live/freeai.punkadillo.com \
  /etc/letsencrypt/renewal-hooks/deploy/oci-lb-cert.sh

# 7. Confirm renewal+hook are wired (won't renew yet — outside the 30-day window).
sudo /opt/le-certbot/venv/bin/certbot renew --dry-run
```

## Schedule it

certbot installs a systemd timer by default; confirm it's active:

```bash
systemctl list-timers | grep certbot   # or: systemctl status certbot.timer
```

If the venv install didn't register a timer, add a daily root cron mirroring the
Mac's 03:30 launchd job:

```bash
echo '30 3 * * * root /opt/le-certbot/venv/bin/certbot renew --quiet' \
  | sudo tee /etc/cron.d/le-certbot
```

## Decommission the Mac job (only after a successful real renewal on the instance)

```bash
launchctl unload ~/Library/LaunchAgents/com.freellmapi.certrenew.plist
# keep ~/le-certbot as a fallback until you've seen one instance renewal land.
```

## Notes

- The cert OCID is **stable**; both the Mac hook and the instance hook only add a
  new *version*, so the LB's mTLS listener (which references the OCID) serves the
  fresh cert with no listener change and no Terraform drift.
- Two certbot accounts (Mac + instance) issuing the same domain is harmless — LE
  allows it, and only one machine should run the timer at a time.
- Tighten later by moving the Cloudflare token into Vault and fetching it at boot
  via instance principal, the same pattern as `ENCRYPTION_KEY` (Phase 4).
