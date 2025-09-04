#!/bin/bash

SCREENSHOT_DIR="$HOME/Pictures"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILE_FORMAT="png"
DUNST_CMD="dunstify"

# Screenshot enhancement settings
PADDING=10          # Padding in pixels
CORNER_RADIUS=10    # Corner radius for rounded corners
GRADIENT_START="#4a90e2"  # Left side gradient color
GRADIENT_END="#50e3c2"    # Right side gradient color

# Parse command line arguments
MODE="${1:-area}"  # [area|window|output]
USE_SATTY=false

# Alt modifier / explicit "satty" arg triggers editor
if [[ "$2" == "satty" || "$2" == "alt" ]]; then
  USE_SATTY=true
fi

show_usage() {
  echo "Usage: $0 [area|window|output] [satty|alt]"
  echo "  area   - Select an area to capture (default)"
  echo "  window - Select an application window to capture"
  echo "  output - Select a monitor/output to capture"
  echo ""
  echo "  satty  - Open in satty for annotation (use with Alt key)"
  echo ""
  echo "Example: $0 area satty"
  exit 1
}

add_padding_and_corners() {
  local input_file="$1"
  local output_file="$2"

  if ! command -v convert >/dev/null 2>&1; then
    echo "ImageMagick not found. Install it with: sudo pacman -S imagemagick"
    cp -- "$input_file" "$output_file"
    return 0
  fi

  local original_width
  local original_height
  original_width=$(identify -ping -format "%w" "$input_file")
  original_height=$(identify -ping -format "%h" "$input_file")

  local final_width=$((original_width + 2 * PADDING))
  local final_height=$((original_height + 2 * PADDING))

  local temp_rounded="$SCREENSHOT_DIR/temp_rounded_${TIMESTAMP}.${FILE_FORMAT}"

  convert "$input_file" \
    \( +clone -alpha extract \
       -draw "fill black polygon 0,0 0,${CORNER_RADIUS} ${CORNER_RADIUS},0 \
              fill white circle ${CORNER_RADIUS},${CORNER_RADIUS} ${CORNER_RADIUS},0" \
       \( +clone -flip \) -compose Multiply -composite \
       \( +clone -flop \) -compose Multiply -composite \
    \) -alpha off -compose CopyOpacity -composite \
    "$temp_rounded"

  convert -size "${final_width}x${final_height}" \
    xc:"${GRADIENT_START}" \
    \( -size "${final_width}x1" "gradient:${GRADIENT_START}-${GRADIENT_END}" -scale "${final_width}x${final_height}!" \) \
    -compose over -composite \
    "$temp_rounded" \
    -gravity center \
    -composite \
    "$output_file"

  rm -f -- "$temp_rounded"
  if [[ "$input_file" != "$output_file" ]]; then
    rm -f -- "$input_file"
  fi
}

save_screenshot() {
  mkdir -p -- "$SCREENSHOT_DIR"
  local temp_filename="$SCREENSHOT_DIR/temp_screenshot_${TIMESTAMP}.${FILE_FORMAT}"
  local final_filename="$SCREENSHOT_DIR/screenshot_${TIMESTAMP}.${FILE_FORMAT}"
  local geometry=""
  local capture_cmd=""

  case "$MODE" in
    area)
      geometry=$(slurp)
      if [[ -z "$geometry" ]]; then
        "$DUNST_CMD" "Screenshot cancelled" -u low
        return 1
      fi
      capture_cmd="grim -g \"$geometry\" \"$temp_filename\""
      ;;
    window)
      "$DUNST_CMD" "Click on a window to capture" -t 2000
      geometry=$(swaymsg -t get_tree | jq -r '
        .. | objects |
        select(.pid and .visible and .type == "con") |
        "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height) \(.app_id // .window_properties.class // "Unknown")"
      ' | slurp -r)
      if [[ -z "$geometry" ]]; then
        "$DUNST_CMD" "No window selected" -u low
        return 1
      fi
      capture_cmd="grim -g \"$geometry\" \"$temp_filename\""
      ;;
    output)
      geometry=$(slurp -o)
      if [[ -z "$geometry" ]]; then
        "$DUNST_CMD" "No output selected" -u low
        return 1
      fi
      capture_cmd="grim -g \"$geometry\" \"$temp_filename\""
      ;;
    *)
      show_usage
      ;;
  esac

  eval "$capture_cmd"
  if [[ $? -ne 0 ]]; then
    "$DUNST_CMD" "Error capturing screenshot" -u critical
    return 1
  fi

  add_padding_and_corners "$temp_filename" "$final_filename"

  if [[ "$USE_SATTY" == true ]]; then
    if command -v satty >/dev/null 2>&1; then
      # Use a temp output to avoid in-place write issues
      local satty_output="$SCREENSHOT_DIR/satty_${TIMESTAMP}.${FILE_FORMAT}"

      satty \
        --filename "$final_filename" \
        --output-filename "$satty_output" \
        --early-exit \
        --actions-on-enter save-to-clipboard \
        --save-after-copy \
        --copy-command 'wl-copy'

      if [[ -f "$satty_output" ]]; then
        mv -f -- "$satty_output" "$final_filename"
        "$DUNST_CMD" "Screenshot edited and saved to $final_filename" -u low
      else
        # User likely canceled; still copy existing file
        wl-copy < "$final_filename"
        "$DUNST_CMD" "Screenshot saved to $final_filename (Satty cancelled)" -u low
      fi
    else
      "$DUNST_CMD" "Satty not found. Install it with: sudo pacman -S satty" -u normal
      wl-copy < "$final_filename"
      "$DUNST_CMD" "Screenshot saved to $final_filename and copied to clipboard." -u low
    fi
  else
    wl-copy < "$final_filename"
    case "$MODE" in
      area)   "$DUNST_CMD" "Area screenshot saved to $final_filename and copied to clipboard." -u low ;;
      window) "$DUNST_CMD" "Window screenshot saved to $final_filename and copied to clipboard." -u low ;;
      output) "$DUNST_CMD" "Output screenshot saved to $final_filename and copied to clipboard." -u low ;;
    esac
  fi

  return 0
}

case "$1" in
  area|window|output|"")
    save_screenshot
    ;;
  -h|--help|help)
    show_usage
    ;;
  *)
    echo "Invalid mode: $1"
    show_usage
    ;;
esac
