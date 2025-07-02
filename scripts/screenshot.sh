#!/bin/bash

SCREENSHOT_DIR="$HOME/Pictures"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILE_FORMAT="png"
DUNST_CMD="dunstify"

# Parse command line arguments
MODE="${1:-area}"  # Default to area if no argument provided

show_usage() {
    echo "Usage: $0 [area|full|window|output]"
    echo "  area   - Select an area to capture (default)"
    echo "  full   - Capture all monitors"
    echo "  window - Select an application window to capture"
    echo "  output - Select a monitor/output to capture"
    exit 1
}

get_window_at_cursor() {
    # Get window under cursor using swaymsg
    # This will show a crosshair cursor and wait for a click
    swaymsg -t get_tree | jq -r --arg x $(slurp -p | cut -d, -f1) --arg y $(slurp -p | cut -d, -f2 | cut -d' ' -f1) '
        .. | objects |
        select(.pid and .visible and .type == "con" and 
               .rect.x <= ($x | tonumber) and 
               .rect.x + .rect.width >= ($x | tonumber) and
               .rect.y <= ($y | tonumber) and 
               .rect.y + .rect.height >= ($y | tonumber)) |
        "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)" | @sh' | head -1 | tr -d "'"
}

save_screenshot() {
    mkdir -p "$SCREENSHOT_DIR"
    local filename="$SCREENSHOT_DIR/screenshot_${TIMESTAMP}.${FILE_FORMAT}"
    local geometry=""
    local capture_cmd=""

    case "$MODE" in
        area)
            geometry=$(slurp)
            if [ -z "$geometry" ]; then
                "$DUNST_CMD" "Screenshot cancelled" -u low
                return 1
            fi
            capture_cmd="grim -g \"$geometry\" \"$filename\""
            ;;
        full)
            capture_cmd="grim \"$filename\""
            ;;
        window)
            # Get all windows and let user select one
            "$DUNST_CMD" "Click on a window to capture" -t 2000
            geometry=$(swaymsg -t get_tree | jq -r '
                .. | objects | 
                select(.pid and .visible and .type == "con") | 
                "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height) \(.app_id // .window_properties.class // "Unknown")"
            ' | slurp -r)
            if [ -z "$geometry" ]; then
                "$DUNST_CMD" "No window selected" -u low
                return 1
            fi
            capture_cmd="grim -g \"$geometry\" \"$filename\""
            ;;
        output)
            # Use slurp -o for monitor/output selection
            geometry=$(slurp -o)
            if [ -z "$geometry" ]; then
                "$DUNST_CMD" "No output selected" -u low
                return 1
            fi
            capture_cmd="grim -g \"$geometry\" \"$filename\""
            ;;
        *)
            show_usage
            ;;
    esac

    # Execute the capture command
    eval $capture_cmd

    if [ $? -ne 0 ]; then
        "$DUNST_CMD" "Error saving screenshot to $filename" -u critical -i error
        return 1
    fi

    # Copy to clipboard
    wl-copy < "$filename"

    # Notify user
    case "$MODE" in
        area)
            "$DUNST_CMD" "Area screenshot saved to $filename and copied to clipboard." -u low -i image
            ;;
        full)
            "$DUNST_CMD" "Full screenshot saved to $filename and copied to clipboard." -u low -i image
            ;;
        window)
            "$DUNST_CMD" "Window screenshot saved to $filename and copied to clipboard." -u low -i image
            ;;
        output)
            "$DUNST_CMD" "Output screenshot saved to $filename and copied to clipboard." -u low -i image
            ;;
    esac

    return 0
}

# Validate argument
case "$1" in
    area|full|window|output|"")
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
