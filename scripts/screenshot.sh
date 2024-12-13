#!/bin/bash

SCREENSHOT_DIR="$HOME/Pictures"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILE_FORMAT="png" 
DUNST_CMD="dunstify"

save_screenshot() {
  mkdir -p "$SCREENSHOT_DIR"

  local filename="$SCREENSHOT_DIR/screenshot_${TIMESTAMP}.${FILE_FORMAT}"

  grim -g "$(slurp)" "$filename"

  if [ $? -ne 0 ]; then
    "$DUNST_CMD" "Error saving screenshot to $filename" -u critical -i error
    return 1
  fi

  wl-copy < "$filename"

  "$DUNST_CMD" "Screenshot saved to $filename and copied to clipboard." -u low -i image
  return 0
}

save_screenshot
