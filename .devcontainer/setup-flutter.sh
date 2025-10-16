#!/usr/bin/env bash
set -euo pipefail

# Base deps for Flutter CLI
sudo apt-get update -y
sudo apt-get install -y git curl unzip xz-utils libglu1-mesa

# Install Flutter (stable) under $HOME
if [ ! -d "$HOME/flutter" ]; then
  git clone --depth=1 -b stable https://github.com/flutter/flutter.git "$HOME/flutter"
fi

# Make Flutter available now and for future shells
if ! grep -q 'flutter/bin' "$HOME/.bashrc"; then
  echo 'export PATH="$PATH:$HOME/flutter/bin"' >> "$HOME/.bashrc"
fi
export PATH="$PATH:$HOME/flutter/bin"

# Enable web and verify toolchain
flutter --version
flutter config --enable-web
flutter doctor -v
