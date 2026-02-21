#!/bin/zsh
# Load environment before running command
source "$HOME/.zshrc" 2>/dev/null || true

exec "$@"
