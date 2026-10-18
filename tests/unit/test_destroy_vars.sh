#!/usr/bin/env bash
# Testa cdw_local_key_fingerprint e cdw_export_tf_vars_for_destroy: a
# destruição nunca deve exigir a chave local nem rede disponível.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$ROOT/scripts/lib/tf.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "destruição sem depender da chave local:"

ssh-keygen -q -t ed25519 -N '' -f "$TMP/id_test" >/dev/null
CDW_SSH_PUBLIC_KEY_FILE="$TMP/id_test.pub"
fp1="$(cdw_local_key_fingerprint)"
fp2="$(cdw_local_key_fingerprint)"
assert_status "$fp1" "$fp2" "fingerprint é estável para a mesma chave"
assert_status 64 "${#fp1}" "fingerprint tem 64 caracteres (sha256 hex)"

ssh-keygen -q -t ed25519 -N '' -f "$TMP/id_other" >/dev/null
CDW_SSH_PUBLIC_KEY_FILE="$TMP/id_other.pub"
fp3="$(cdw_local_key_fingerprint)"
assert_not_contains "$fp3" "$fp1" "chaves diferentes dão fingerprints diferentes"

unset TF_VAR_ssh_public_key TF_VAR_admin_cidr
CDW_SSH_PUBLIC_KEY_FILE="$TMP/chave-inexistente.pub"
CDW_IP_ECHO_URL="http://127.0.0.1:1"
cdw_export_tf_vars_for_destroy 2>/dev/null
assert_contains "$TF_VAR_ssh_public_key" "ssh-ed25519 " "sem chave local, usa chave fictícia com formato válido"
assert_status "192.0.2.1/32" "$TF_VAR_admin_cidr" "sem rede, usa CIDR fictício válido"

unset TF_VAR_ssh_public_key TF_VAR_admin_cidr
CDW_SSH_PUBLIC_KEY_FILE="$TMP/id_test.pub"
cdw_export_tf_vars_for_destroy
assert_status "$(cat "$TMP/id_test.pub")" "$TF_VAR_ssh_public_key" "com a chave presente, usa o conteúdo real"

finish
