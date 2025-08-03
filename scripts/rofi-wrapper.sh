#!/bin/zsh
# Load environment before running command
source /home/cjvnjde/.zshrc 2>/dev/null || true

exec "$@"
