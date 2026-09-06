#!/bin/zsh
# Install Sparkle's sign_update / generate_keys from the official release into ~/.local/share/sparkle-tools.
set -euo pipefail
V=${1:-2.9.6}
T=$(mktemp -d)
curl -sL -o "$T/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$V/Sparkle-$V.tar.xz"
mkdir -p "$T/x" ~/.local/share/sparkle-tools
tar -xf "$T/sparkle.tar.xz" -C "$T/x"
cp "$T/x/bin/sign_update" "$T/x/bin/generate_keys" ~/.local/share/sparkle-tools/
rm -rf "$T"
echo "installed Sparkle $V tools to ~/.local/share/sparkle-tools"
