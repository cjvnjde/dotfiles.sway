!/bin/bash

SCREENSHOT_DIR="$HOME/Pictures"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILE_FORMAT="png"
DUNST_CMD="dunstify"

# Screenshot enhancement settings
PADDING=20  # Padding in pixels
CORNER_RADIUS=10  # Corner radius for rounded corners
GRADIENT_START="#4a90e2"  # Left side gradient color (Nordic theme)
GRADIENT_END="#50e3c2"    # Right side gradient color

# Parse command line arguments
MODE="${1:-area}"  # Default to area if no argument provided
USE_SWAPPY=false

# Check if Alt modifier is pressed (passed as second argument)
if [ "$2" = "swappy" ] || [ "$2" = "alt" ]; then
    USE_SWAPPY=true
fi

show_usage() {
    echo "Usage: $0 [area|window|output] [swappy|alt]"
    echo "  area   - Select an area to capture (default)"
    echo "  window - Select an application window to capture"
    echo "  output - Select a monitor/output to capture"
    echo ""
    echo "  swappy - Open in swappy for annotation (use with Alt key)"
    echo ""
    echo "Example: $0 area swappy"
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

add_padding_and_corners() {
    local input_file="$1"
    local output_file="$2"
    
    # Check if ImageMagick is available
    if ! command -v convert &> /dev/null; then
        echo "ImageMagick not found. Install it with: sudo pacman -S imagemagick"
        cp "$input_file" "$output_file"
        return 0
    fi
    
    # Get dimensions of the original image
    local original_width=$(identify -ping -format "%w" "$input_file")
    local original_height=$(identify -ping -format "%h" "$input_file")
    
    # Calculate final dimensions with padding
    local final_width=$((original_width + 2 * PADDING))
    local final_height=$((original_height + 2 * PADDING))
    
    # First, apply rounded corners to the original image
    local temp_rounded="$SCREENSHOT_DIR/temp_rounded_${TIMESTAMP}.${FILE_FORMAT}"
    
    # Create rounded corners mask and apply to original image
    convert "$input_file" \
        \( +clone -alpha extract \
           -draw "fill black polygon 0,0 0,${CORNER_RADIUS} ${CORNER_RADIUS},0 \
                  fill white circle ${CORNER_RADIUS},${CORNER_RADIUS} ${CORNER_RADIUS},0" \
           \( +clone -flip \) -compose Multiply -composite \
           \( +clone -flop \) -compose Multiply -composite \
        \) -alpha off -compose CopyOpacity -composite \
        "$temp_rounded"
    
    # Create gradient background (left to right) and place rounded image on top
    convert -size ${final_width}x${final_height} \
        xc:"${GRADIENT_START}" \
        \( -size ${final_width}x1 gradient:"${GRADIENT_START}-${GRADIENT_END}" -scale ${final_width}x${final_height}! \) \
        -compose over -composite \
        "$temp_rounded" \
        -gravity center \
        -composite \
        "$output_file"
    
    # Clean up temporary files
    rm "$temp_rounded"
    if [ "$input_file" != "$output_file" ]; then
        rm "$input_file"
    fi
}

save_screenshot() {
    mkdir -p "$SCREENSHOT_DIR"
    local temp_filename="$SCREENSHOT_DIR/temp_screenshot_${TIMESTAMP}.${FILE_FORMAT}"
    local final_filename="$SCREENSHOT_DIR/screenshot_${TIMESTAMP}.${FILE_FORMAT}"
    local geometry=""
    local capture_cmd=""

    case "$MODE" in
        area)
            geometry=$(slurp)
            if [ -z "$geometry" ]; then
                "$DUNST_CMD" "Screenshot cancelled" -u low
                return 1
            fi
            capture_cmd="grim -g \"$geometry\" \"$temp_filename\""
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
            capture_cmd="grim -g \"$geometry\" \"$temp_filename\""
            ;;
        output)
            # Use slurp -o for monitor/output selection
            geometry=$(slurp -o)
            if [ -z "$geometry" ]; then
                "$DUNST_CMD" "No output selected" -u low
                return 1
            fi
            capture_cmd="grim -g \"$geometry\" \"$temp_filename\""
            ;;
        *)
            show_usage
            ;;
    esac

    # Execute the capture command
    eval $capture_cmd
    if [ $? -ne 0 ]; then
        "$DUNST_CMD" "Error capturing screenshot" -u critical -i error
        return 1
    fi

    # Add padding and rounded corners
    add_padding_and_corners "$temp_filename" "$final_filename"

    # If swappy is requested, open the screenshot in swappy
    if [ "$USE_SWAPPY" = true ]; then
        if command -v swappy &> /dev/null; then
            # Create a temporary file for swappy output
            local swappy_output="$SCREENSHOT_DIR/swappy_${TIMESTAMP}.${FILE_FORMAT}"
            
            # Open swappy with the screenshot
            swappy -f "$final_filename" -o "$swappy_output"
            
            # Check if swappy saved a file (user didn't cancel)
            if [ -f "$swappy_output" ]; then
                # Replace the original with swappy output
                mv "$swappy_output" "$final_filename"
                
                # Copy to clipboard
                wl-copy < "$final_filename"
                
                "$DUNST_CMD" "Screenshot edited and saved to $final_filename" -u low -i image
            else
                # User cancelled swappy, still keep the original
                wl-copy < "$final_filename"
                "$DUNST_CMD" "Screenshot saved to $final_filename (swappy cancelled)" -u low -i image
            fi
        else
            "$DUNST_CMD" "Swappy not found. Install it with: sudo pacman -S swappy" -u normal
            # Fall back to normal behavior
            wl-copy < "$final_filename"
            "$DUNST_CMD" "Screenshot saved to $final_filename and copied to clipboard." -u low -i image
        fi
    else
        # Normal mode - just copy to clipboard and notify
        wl-copy < "$final_filename"
        
        # Notify user
        case "$MODE" in
            area)
                "$DUNST_CMD" "Area screenshot saved to $final_filename and copied to clipboard." -u low -i image
                ;;
            window)
                "$DUNST_CMD" "Window screenshot saved to $final_filename and copied to clipboard." -u low -i image
                ;;
            output)
                "$DUNST_CMD" "Output screenshot saved to $final_filename and copied to clipboard." -u low -i image
                ;;
        esac
    fi

    return 0
}

# Validate argument
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
