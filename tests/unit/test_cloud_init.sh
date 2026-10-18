#!/usr/bin/env bash
# Renderiza o cloud-init com a mesma função templatefile do OpenTofu e valida o
# resultado. Usa `cloud-init schema` quando disponível (CI); não acessa a rede.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

echo "cloud-init:"

if ! tf="$(tf_bin)"; then
	echo "  skip (tofu/terraform ausente)"
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/render.tf" <<HCL
output "user_data" {
  value = templatefile("$ROOT/infrastructure/cloud-init/user-data.yaml.tftpl", {
    username          = "dev"
    ssh_public_key    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey teste"
    admin_cidr        = "203.0.113.10/32"
    bootstrap_version = "2"
    bootstrap_b64     = base64encode(file("$ROOT/scripts/bootstrap.sh"))
  })
}
HCL
(cd "$TMP" && "$tf" init -backend=false -input=false >/dev/null && "$tf" apply -auto-approve -input=false >/dev/null && "$tf" output -raw user_data >"$TMP/user-data.yaml")

assert_status "#cloud-config" "$(head -n1 "$TMP/user-data.yaml")" "primeira linha é #cloud-config"

checks="$(
	python3 -I - "$TMP/user-data.yaml" "$ROOT/scripts/bootstrap.sh" <<'PY'
import base64, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
user = doc["users"][0]
files = {f["path"]: f for f in doc["write_files"]}
boot = base64.b64decode(files["/usr/local/sbin/cdw-bootstrap"]["content"]).decode()
print("disable_root", doc.get("disable_root") is True)
print("ssh_pwauth", doc.get("ssh_pwauth") is False)
print("user", user["name"] == "dev" and user["lock_passwd"] is True)
print("key", user["ssh_authorized_keys"][0].startswith("ssh-ed25519 "))
print("bootstrap", boot == open(sys.argv[2]).read())
print("env", "CDW_USER=dev" in files["/etc/cdw/bootstrap.env"]["content"])
print("runcmd", doc["runcmd"] == [["/usr/local/sbin/cdw-bootstrap"]])
PY
)"
while read -r name result; do
	assert_status True "$result" "cloud-init: $name"
done <<<"$checks"

size="$(wc -c <"$TMP/user-data.yaml")"
if ((size < 32768)); then pass "user-data com $size bytes (< 32 KiB da Hetzner)"; else flunk "user-data com $size bytes excede 32 KiB"; fi

if command -v cloud-init >/dev/null 2>&1; then
	if cloud-init schema --config-file "$TMP/user-data.yaml" >/dev/null 2>&1; then
		pass "cloud-init schema válido"
	else
		flunk "cloud-init schema inválido: $(cloud-init schema --config-file "$TMP/user-data.yaml" 2>&1 | tail -n 3)"
	fi
else
	echo "  skip cloud-init schema (cloud-init não instalado)"
fi

finish
