#!/usr/bin/env bash
# One-time helper: stand up an OCI Bastion in the app's PRIVATE subnet and open a
# port-forwarding session to the instance's SSH (22), so you can reach the box to
# install the Let's-Encrypt deploy hook (oci-lb-cert-deploy-hook.sh).
#
# Why port-forwarding (not managed SSH): port-forwarding needs no Bastion plugin
# on the instance and works purely at the network layer — the matching ingress is
# the `app_ssh_bastion` NSG rule (SSH/22 from the private subnet CIDR), so you must
# have applied with enable_bastion_ssh = true first.
#
# Prereqs: oci CLI authenticated (a config profile, not instance principal), and
# `terraform output` available from the terraform/ dir. Run from anywhere:
#   SSH_PUB=~/.ssh/id_ed25519.pub ./scripts/bastion-session.sh
set -euo pipefail

cd "$(dirname "$0")/.."   # -> terraform/

SSH_PUB="${SSH_PUB:-$HOME/.ssh/id_ed25519.pub}"
LOCAL_PORT="${LOCAL_PORT:-2222}"     # local port the tunnel will listen on
SESSION_TTL="${SESSION_TTL:-10800}"  # 3h, the max for a Bastion session
BASTION_NAME="${BASTION_NAME:-freellmapi-bastion}"

[ -f "$SSH_PUB" ] || { echo "SSH public key not found: $SSH_PUB (set SSH_PUB=...)" >&2; exit 1; }

INSTANCE_OCID="$(terraform output -raw instance_ocid)"
PRIVATE_IP="$(terraform output -raw instance_private_ip)"

# Derive compartment + the instance's subnet straight from the instance, so we
# don't depend on tfvars (which is gitignored) or add new TF outputs.
COMPARTMENT="$(oci compute instance get --instance-id "$INSTANCE_OCID" \
  --query 'data."compartment-id"' --raw-output)"
SUBNET="$(oci compute instance list-vnics --instance-id "$INSTANCE_OCID" \
  --query 'data[0]."subnet-id"' --raw-output)"

echo "instance   : $INSTANCE_OCID"
echo "private ip : $PRIVATE_IP"
echo "subnet     : $SUBNET"

# Reuse an existing ACTIVE bastion of this name, else create one in the private subnet.
BASTION="$(oci bastion bastion list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='$BASTION_NAME' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
  --raw-output 2>/dev/null || true)"
if [ -z "${BASTION:-}" ] || [ "$BASTION" = "null" ]; then
  echo "creating bastion '$BASTION_NAME' in the private subnet (this takes ~1-2 min)..."
  BASTION="$(oci bastion bastion create \
    --bastion-type STANDARD \
    --compartment-id "$COMPARTMENT" \
    --target-subnet-id "$SUBNET" \
    --name "$BASTION_NAME" \
    --client-cidr-block-allow-list '["0.0.0.0/0"]' \
    --wait-for-state ACTIVE \
    --query 'data.id' --raw-output)"
fi
echo "bastion    : $BASTION"

echo "opening port-forwarding session to $PRIVATE_IP:22 ..."
SID="$(oci bastion session create-port-forwarding \
  --bastion-id "$BASTION" \
  --display-name freellmapi-pf \
  --key-type PUB \
  --ssh-public-key-file "$SSH_PUB" \
  --target-private-ip "$PRIVATE_IP" \
  --target-port 22 \
  --session-ttl "$SESSION_TTL" \
  --wait-for-state ACTIVE \
  --query 'data.id' --raw-output)"
echo "session    : $SID"

# OCI returns the tunnel command with a <privateKey> placeholder. Print it, plus
# the second-terminal command you actually log in with.
TUNNEL="$(oci bastion session get --session-id "$SID" \
  --query 'data."ssh-metadata".command' --raw-output)"

PRIV="${SSH_PRIV:-${SSH_PUB%.pub}}"
cat <<EOF

--- Terminal 1: open the tunnel (leave it running) ---------------------------
${TUNNEL/<privateKey>/$PRIV}

# If the printed command lacks a local-forward, this is the equivalent form:
# ssh -i $PRIV -N -L ${LOCAL_PORT}:${PRIVATE_IP}:22 -p 22 ${SID}@host.bastion.\$(oci iam region list --query 'data[0].name' --raw-output 2>/dev/null || echo '<region>').oci.oraclecloud.com

--- Terminal 2: log in through the tunnel ------------------------------------
ssh -i $PRIV -p ${LOCAL_PORT} ubuntu@localhost

# Then install the deploy hook (see scripts/oci-lb-cert-deploy-hook.sh header).
EOF
