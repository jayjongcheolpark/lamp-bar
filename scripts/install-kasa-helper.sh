#!/bin/sh
# Installs the optional python-kasa helper for Kasa plugs that need a TP-Link login.
# Plugs on the legacy local protocol work without it.
set -eu
dir="$HOME/Library/Application Support/LampBar"
mkdir -p "$dir"
if command -v uv >/dev/null 2>&1; then
  uv venv --quiet --allow-existing "$dir/kasa-venv"
  uv pip install --quiet --python "$dir/kasa-venv/bin/python" 'python-kasa>=0.10'
else
  python3 -m venv "$dir/kasa-venv"
  "$dir/kasa-venv/bin/pip" install --quiet 'python-kasa>=0.10'
fi
cp "$(dirname "$0")/kasa-helper.py" "$dir/kasa-helper.py"
echo "Installed the Kasa login helper in $dir"
