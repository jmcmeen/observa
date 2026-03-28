#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== Observa Uninstall ==="
echo "This will stop all containers and remove ALL associated containers, images, and volumes."
echo ""
read -rp "Are you sure? (y/N): " confirm
if [[ "${confirm,,}" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "Stopping and removing containers, networks, images, and volumes..."
docker compose down --rmi all --volumes --remove-orphans

echo ""
echo "Uninstall complete. All Observa containers, images, and volumes have been removed."
