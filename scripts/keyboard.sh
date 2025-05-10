#!/bin/bash

# Exit on error, treat unset variables as an error
# set -euo pipefail # Uncomment for stricter error handling, may require more checks

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

# The name of the currently active layout (with spaces replaced by underscores)
# This is derived from DEFAULT_LANGUAGES and the validated xkb_active_layout_index
# xkb_active_layout_name="${DEFAULT_LANGUAGES[$xkb_active_layout_index]}" # Not strictly needed if we use index

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
            # dunstify "Language Switcher Warning" "LANGUAGES_FILE initialized empty as no default languages found."
        fi
    fi

    if [[ ! -f "$SPACE_COUNT_FILE" ]]; then
        echo "0" > "$SPACE_COUNT_FILE"
    fi
}

# Function to get the current language from the script's perspective (first in LANGUAGES_FILE)
_get_current_lang() {
    # This function assumes _init_cache has been called by the invoking function.
    # LANGUAGES_FILE should be populated and its first entry should reflect the active or intended active language.
    local languages_str
    languages_str=$(cat "$LANGUAGES_FILE" 2>/dev/null) # Suppress error if file non-existent
    local langs_arr
    read -r -a langs_arr <<< "$languages_str" 

    if [[ ${#langs_arr[@]} -gt 0 && -n "${langs_arr[0]}" ]]; then
        echo "${langs_arr[0]}"
    else
        # Fallback: If LANGUAGES_FILE is empty/unreadable, report what system had at script start.
        # This indicates an issue, as _init_cache should prevent this.
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

# Cycles languages: moves the last language to the first position in the array (passed by name reference)
_cycle_langs_last_to_first() {
    local -n arr_ref=$1 # Pass array by reference (requires bash 4.3+)
    local num_langs=${#arr_ref[@]}

    if [[ $num_langs -ge 2 ]]; then
        local last_lang="${arr_ref[$((num_langs - 1))]}"
        # Shift elements to the right to make space at the beginning
        for (( i=num_langs-1; i>0; i-- )); do
            arr_ref[$i]="${arr_ref[$((i-1))]}"
        done
        arr_ref[0]="$last_lang" # Place the original last element at the front
        return 0 # Success
    fi
    return 1 # Not enough languages to cycle
}

# Action when Super key is pressed
press_super() {
    _init_cache
    echo "true" > "$SUPER_PRESSED_FILE"
    echo "0" > "$SPACE_COUNT_FILE" # Reset space count on new Super press
    
    local current_lang_display
    current_lang_display=$(_get_current_lang)
    # dunstify "Language Switcher" "Super PRESSED. Current: $current_lang_display. Space count reset."
}

# Action when Super key is released
release_super() {
    _init_cache
    echo "false" > "$SUPER_PRESSED_FILE"
    
    local current_lang_display
    current_lang_display=$(_get_current_lang)
    # dunstify "Language Switcher" "Super RELEASED. Current: $current_lang_display."
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
        # dunstify "Language Switcher" "Warning: Language cache empty. Attempting to re-initialize..."
        
        # Fetch live system data for re-initialization
        local current_inputs_live_recovery
        current_inputs_live_recovery=$(swaymsg -t get_inputs -r)
        local json_data_live_recovery
        json_data_live_recovery=$(echo "$current_inputs_live_recovery" | jq -r 'first(.[] | select(.type == "keyboard" and .xkb_layout_names)) // empty')

        if [[ -n "$json_data_live_recovery" ]]; then
            local active_idx_live_recovery
            active_idx_live_recovery=$(echo "$json_data_live_recovery" | jq -r '.xkb_active_layout_index // "0"')
            
            # Use the global DEFAULT_LANGUAGES for the list of names and their indices.
            # The critical part is getting the *current active index* for *that list*.
            if [[ "$active_idx_live_recovery" -lt "${#DEFAULT_LANGUAGES[@]}" ]]; then
                local active_lang_now="${DEFAULT_LANGUAGES[$active_idx_live_recovery]}"
                
                langs_arr=() # Reset langs_arr
                langs_arr+=("$active_lang_now") # Current system active language first
                for lang_name_iter in "${DEFAULT_LANGUAGES[@]}"; do
                    if [[ "$lang_name_iter" != "$active_lang_now" ]]; then
                        langs_arr+=("$lang_name_iter")
                    fi
                done
                echo "${langs_arr[*]}" > "$LANGUAGES_FILE" # Persist this recovery
                num_langs=${#langs_arr[@]} # Update num_langs
                # dunstify "Language Switcher" "Re-initialized languages. Active: ${langs_arr[0]}"
            else
                 dunstify -u critical "Language Switcher Error" "Could not re-initialize: live active index out of bounds."
                 return 1 # Critical failure to re-initialize
            fi
        else
            dunstify -u critical "Language Switcher Error" "Could not re-initialize: failed to get live keyboard data."
            return 1 # Critical failure
        fi
    fi

    # After potential recovery, check num_langs again
    if [[ $num_langs -eq 0 ]]; then
        dunstify -u critical "Language Switcher Error" "No languages available even after re-init attempt."
        return 1
    elif [[ $num_langs -eq 1 ]]; then
        # dunstify "Language Switcher" "Only one language configured: ${langs_arr[0]}. No switch possible."
        return 0
    fi

    local action_description=""
    local final_message_segment=""
    local current_space_press_for_this_action # Holds updated count if super is pressed

    if [[ "$super_is_pressed" == "true" ]]; then
        current_space_press_for_this_action=$((space_count_before_action + 1))
        echo "$current_space_press_for_this_action" > "$SPACE_COUNT_FILE" # Update persisted count

        if [[ "$current_space_press_for_this_action" -eq 1 ]]; then
            _swap_first_two_langs langs_arr
            action_description="TOGGLE"
        else
            _cycle_langs_last_to_first langs_arr
            action_description="CYCLE"
        fi
        final_message_segment="$action_description to ${langs_arr[0]} (Super held, ${current_space_press_for_this_action}x space)"
    else
        # Super not pressed: default to swap first two
        _swap_first_two_langs langs_arr
        action_description="TOGGLE"
        final_message_segment="$action_description to ${langs_arr[0]} (Super not active)"
    fi
    
    # At this point, langs_arr[0] is the NAME of the target layout (with underscores)
    local target_layout_name="${langs_arr[0]}"
    local target_layout_system_index=-1

    # Find the system index of the target_layout_name in the original DEFAULT_LANGUAGES array
    for i in "${!DEFAULT_LANGUAGES[@]}"; do
       if [[ "${DEFAULT_LANGUAGES[$i]}" == "$target_layout_name" ]]; then
           target_layout_system_index=$i
           break
       fi
    done

    if [[ "$target_layout_system_index" -ne -1 ]]; then
        # Switch the system keyboard layout
        if swaymsg input "$identifier" xkb_switch_layout "$target_layout_system_index"; then
            # If switch is successful, save the new language order to the cache file
            echo "${langs_arr[*]}" > "$LANGUAGES_FILE"
            # dunstify "Language Switcher" "Switched to $target_layout_name. ($final_message_segment)"
        else
            dunstify -u critical "Language Switcher Error" "Failed to execute swaymsg to switch layout to $target_layout_name (Index: $target_layout_system_index)."
            # LANGUAGES_FILE is not updated, as the switch failed. Script's cache might be out of sync.
        fi
    else
        # This should ideally not happen if langs_arr contains valid names from DEFAULT_LANGUAGES
        dunstify -u critical "Language Switcher Error" "Target layout '$target_layout_name' not found in system layouts. Cache: [${langs_arr[*]}]. System: [${DEFAULT_LANGUAGES[*]}]."
        # Consider resetting LANGUAGES_FILE to a sane state here if this error occurs.
    fi
}

# Main script execution: Call the function passed as the first argument
if [[ -n "$1" ]] && declare -f "$1" > /dev/null; then
    "$@" # Call the function with all its arguments
else
    if [[ -z "$1" ]]; then
        echo "Usage: $0 {press_super|release_super|toggle_language}"
    else
        echo "Error: Function '$1' not found."
        echo "Available functions: press_super, release_super, toggle_language"
    fi
    exit 1
fi
