#!/bin/bash

# Exit on error, treat unset variables as an error
# set -euo pipefail # Uncomment for stricter error handling, may require more checks

# --- Configuration ---
# Set to "false" to disable informational notifications (errors/warnings will still show)
SHOW_INFO_NOTIFICATIONS="false"
# --- End Configuration ---

CACHE_BASE_PATH="$HOME/.cache"
LANG_SWITCHER_DIR="$CACHE_BASE_PATH/language_switcher"
SUPER_PRESSED_FILE="$LANG_SWITCHER_DIR/super_pressed_state"
LANGUAGES_FILE="$LANG_SWITCHER_DIR/languages_list"
SPACE_COUNT_FILE="$LANG_SWITCHER_DIR/space_press_count"

# Fetch current keyboard information from sway
current_inputs=$(swaymsg -t get_inputs -r)
# Select the first keyboard that has xkb_layout_names
json_data=$(echo "$current_inputs" | jq -r 'first(.[] | select(.type == "keyboard" and .xkb_layout_names)) // empty')

# Check if keyboard information was found
if [[ -z "$json_data" ]]; then
    dunstify -u critical "Language Switcher Error" "Could not find a keyboard with xkb_layout_names from swaymsg. Exiting."
    exit 1
fi

# Extract keyboard identifier
identifier=$(echo "$json_data" | jq -r '.identifier')
if [[ -z "$identifier" ]]; then
    dunstify -u critical "Language Switcher Error" "Could not get keyboard identifier. Exiting."
    exit 1
fi

# Extract available layout names. Replace spaces with underscores for easier handling in bash arrays.
# The '?' after [] makes jq output nothing if .xkb_layout_names is null or empty, instead of an error.
mapfile -t DEFAULT_LANGUAGES < <(echo "$json_data" | jq -r '.xkb_layout_names[]?' | tr ' ' '_')

# Extract the index of the currently active layout
# Default to 0 if not found (though it should always be present if xkb_layout_names is)
xkb_active_layout_index=$(echo "$json_data" | jq -r '.xkb_active_layout_index // "0"')

# Check if any layouts were found
if [[ ${#DEFAULT_LANGUAGES[@]} -eq 0 ]] || [[ -z "${DEFAULT_LANGUAGES[0]}" ]]; then
    dunstify -u critical "Language Switcher Error" "No layout names found for the keyboard '$identifier'. Exiting."
    exit 1
fi

# Ensure xkb_active_layout_index is within bounds
if ! [[ "$xkb_active_layout_index" =~ ^[0-9]+$ ]] || [[ "$xkb_active_layout_index" -ge "${#DEFAULT_LANGUAGES[@]}" ]]; then
    dunstify -u warning "Language Switcher Warning" "Active layout index '$xkb_active_layout_index' is invalid or out of bounds. Defaulting to 0."
    xkb_active_layout_index=0
fi

# Function to send an informational notification, respects SHOW_INFO_NOTIFICATIONS
_notify_info() {
    if [[ "$SHOW_INFO_NOTIFICATIONS" == "true" ]]; then
        dunstify "Language Switcher" "$1"
    fi
}

# Function to initialize cache files and directories
_init_cache() {
    mkdir -p "$LANG_SWITCHER_DIR"
    if [[ ! -f "$SUPER_PRESSED_FILE" ]]; then
        echo "false" > "$SUPER_PRESSED_FILE"
    fi

    # Initialize LANGUAGES_FILE based on current system state if it doesn't exist
    # This ensures the script's language list starts synchronized with the system.
    if [[ ! -f "$LANGUAGES_FILE" ]]; then
        if [[ ${#DEFAULT_LANGUAGES[@]} -gt 0 ]]; then
            # The active layout (name with underscores) should be first in our cached list.
            local current_active_lang_name="${DEFAULT_LANGUAGES[$xkb_active_layout_index]}"
            
            local initial_langs_ordered=()
            initial_langs_ordered+=("$current_active_lang_name") # Active language first

            for lang in "${DEFAULT_LANGUAGES[@]}"; do
                if [[ "$lang" != "$current_active_lang_name" ]]; then
                    initial_langs_ordered+=("$lang")
                fi
            done
            echo "${initial_langs_ordered[*]}" > "$LANGUAGES_FILE"
        else
            # This case should be prevented by earlier checks that exit if DEFAULT_LANGUAGES is empty.
            echo "" > "$LANGUAGES_FILE" 
            # This is a warning, so it should always show
            dunstify -u warning "Language Switcher Warning" "LANGUAGES_FILE initialized empty as no default languages found."
        fi
    fi

    if [[ ! -f "$SPACE_COUNT_FILE" ]]; then
        echo "0" > "$SPACE_COUNT_FILE"
    fi
}

# Function to get the current language from the script's perspective (first in LANGUAGES_FILE)
_get_current_lang() {
    # This function assumes _init_cache has been called by the invoking function.
    local languages_str
    languages_str=$(cat "$LANGUAGES_FILE" 2>/dev/null) # Suppress error if file non-existent
    local langs_arr
    read -r -a langs_arr <<< "$languages_str" 

    if [[ ${#langs_arr[@]} -gt 0 && -n "${langs_arr[0]}" ]]; then
        echo "${langs_arr[0]}"
    else
        # Fallback: If LANGUAGES_FILE is empty/unreadable, report what system had at script start.
        if [[ "$xkb_active_layout_index" -lt "${#DEFAULT_LANGUAGES[@]}" ]]; then
             echo "${DEFAULT_LANGUAGES[$xkb_active_layout_index]}"
        else
            echo "N/A (Error)" # Should not happen if initial checks pass
        fi
    fi
}

# Swaps the first two languages in the provided array (passed by name reference)
_swap_first_two_langs() {
    local -n arr_ref=$1 # Pass array by reference (requires bash 4.3+)
    local num_langs=${#arr_ref[@]}

    if [[ $num_langs -ge 2 ]]; then
        local temp_lang="${arr_ref[0]}"
        arr_ref[0]="${arr_ref[1]}"
        arr_ref[1]="$temp_lang"
        return 0 # Success
    fi
    return 1 # Not enough languages to swap
}

# New function to handle cycling when Super is held.
# For 2 languages, it swaps them (toggles).
# For 3+ languages, it swaps the 1st and 3rd elements, keeping the 2nd "sticky".
_cycle_with_sticky_second() {
    local -n arr_ref=$1 # Pass array by reference
    local num_langs=${#arr_ref[@]}

    if [[ $num_langs -lt 2 ]]; then
        return 1 # Indicate failure or not applicable
    fi

    if [[ $num_langs -eq 2 ]]; then
        _swap_first_two_langs arr_ref
        return 0
    fi

    # For num_langs >= 3:
    local lang_at_idx_0="${arr_ref[0]}"
    local lang_at_idx_2="${arr_ref[2]}" 

    arr_ref[0]="$lang_at_idx_2" 
    arr_ref[2]="$lang_at_idx_0" 
    return 0 # Success
}


# Action when Super key is pressed
press_super() {
    _init_cache
    echo "true" > "$SUPER_PRESSED_FILE"
    echo "0" > "$SPACE_COUNT_FILE" # Reset space count on new Super press
    
    local current_lang_display
    current_lang_display=$(_get_current_lang)
    _notify_info "Super PRESSED. Current: $current_lang_display. Space count reset."
}

# Action when Super key is released
release_super() {
    _init_cache
    echo "false" > "$SUPER_PRESSED_FILE"
    
    local current_lang_display
    current_lang_display=$(_get_current_lang)
    _notify_info "Super RELEASED. Current: $current_lang_display."
}

# Main logic for toggling/cycling language
toggle_language() {
    _init_cache # Ensure cache files exist

    local super_is_pressed
    super_is_pressed=$(cat "$SUPER_PRESSED_FILE")
    local space_count_before_action
    space_count_before_action=$(cat "$SPACE_COUNT_FILE")

    local languages_str
    languages_str=$(cat "$LANGUAGES_FILE")
    local langs_arr # This is the script's ordered list of languages
    read -r -a langs_arr <<< "$languages_str"
    local num_langs=${#langs_arr[@]}

    # Handle cases where LANGUAGES_FILE might be empty or corrupted
    if [[ $num_langs -eq 0 ]]; then
        # This is a warning, so it should always show
        dunstify -u warning "Language Switcher" "Warning: Language cache empty. Attempting to re-initialize..."
        
        local current_inputs_live_recovery
        current_inputs_live_recovery=$(swaymsg -t get_inputs -r)
        local json_data_live_recovery
        json_data_live_recovery=$(echo "$current_inputs_live_recovery" | jq -r 'first(.[] | select(.type == "keyboard" and .xkb_layout_names)) // empty')

        if [[ -n "$json_data_live_recovery" ]]; then
            local active_idx_live_recovery
            active_idx_live_recovery=$(echo "$json_data_live_recovery" | jq -r '.xkb_active_layout_index // "0"')
            
            if [[ "$active_idx_live_recovery" -lt "${#DEFAULT_LANGUAGES[@]}" ]]; then
                local active_lang_now="${DEFAULT_LANGUAGES[$active_idx_live_recovery]}"
                
                langs_arr=() 
                langs_arr+=("$active_lang_now") 
                for lang_name_iter in "${DEFAULT_LANGUAGES[@]}"; do
                    if [[ "$lang_name_iter" != "$active_lang_now" ]]; then
                        langs_arr+=("$lang_name_iter")
                    fi
                done
                echo "${langs_arr[*]}" > "$LANGUAGES_FILE" 
                num_langs=${#langs_arr[@]} 
                _notify_info "Re-initialized languages. Active: ${langs_arr[0]}" # Info about successful re-init
            else
                 dunstify -u critical "Language Switcher Error" "Could not re-initialize: live active index out of bounds."
                 return 1 
            fi
        else
            dunstify -u critical "Language Switcher Error" "Could not re-initialize: failed to get live keyboard data."
            return 1 
        fi
    fi

    # After potential recovery, check num_langs again
    if [[ $num_langs -eq 0 ]]; then
        dunstify -u critical "Language Switcher Error" "No languages available even after re-init attempt."
        return 1
    elif [[ $num_langs -eq 1 ]]; then
        _notify_info "Only one language configured: ${langs_arr[0]}. No switch possible."
        return 0
    fi 

    local action_description=""
    local final_message_segment=""
    local current_space_press_for_this_action 

    if [[ "$super_is_pressed" == "true" ]]; then
        current_space_press_for_this_action=$((space_count_before_action + 1))
        echo "$current_space_press_for_this_action" > "$SPACE_COUNT_FILE" 

        if [[ "$current_space_press_for_this_action" -eq 1 ]]; then
            _swap_first_two_langs langs_arr
            action_description="TOGGLE"
        else
            _cycle_with_sticky_second langs_arr
            action_description="CYCLE"
        fi
        final_message_segment="$action_description to ${langs_arr[0]} (Super held, ${current_space_press_for_this_action}x space)"
    else
        _swap_first_two_langs langs_arr
        action_description="TOGGLE"
        final_message_segment="$action_description to ${langs_arr[0]} (Super not active)"
    fi
    
    local target_layout_name="${langs_arr[0]}"
    local target_layout_system_index=-1

    for i in "${!DEFAULT_LANGUAGES[@]}"; do
       if [[ "${DEFAULT_LANGUAGES[$i]}" == "$target_layout_name" ]]; then
           target_layout_system_index=$i
           break
       fi
    done

    if [[ "$target_layout_system_index" -ne -1 ]]; then
        if swaymsg input "$identifier" xkb_switch_layout "$target_layout_system_index"; then
            echo "${langs_arr[*]}" > "$LANGUAGES_FILE"
            _notify_info "Switched to $target_layout_name. ($final_message_segment)"
        else
            dunstify -u critical "Language Switcher Error" "Failed to execute swaymsg to switch layout to $target_layout_name (Index: $target_layout_system_index)."
        fi
    else
        dunstify -u critical "Language Switcher Error" "Target layout '$target_layout_name' not found in system layouts. Cache: [${langs_arr[*]}]. System: [${DEFAULT_LANGUAGES[*]}]."
    fi
}

# Main script execution: Call the function passed as the first argument
if [[ -n "$1" ]] && declare -f "$1" > /dev/null; then
    "$@" 
else
    if [[ -z "$1" ]]; then
        echo "Usage: $0 {press_super|release_super|toggle_language}"
    else
        echo "Error: Function '$1' not found."
        echo "Available functions: press_super, release_super, toggle_language"
    fi
    exit 1
fi
