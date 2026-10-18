#!/usr/bin/env bash
# Executa todos os testes que não provisionam infraestrutura.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

failed=0
for t in tests/unit/test_*.sh tests/static/test_*.sh; do
	echo "== $t"
	if ! bash "$t"; then failed=$((failed + 1)); fi
done

if ((failed > 0)); then
	echo "Arquivos de teste com falha: $failed"
	exit 1
fi
echo "Todos os testes passaram."
