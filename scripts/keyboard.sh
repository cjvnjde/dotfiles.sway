#!/bin/bash

# --- Configuration ---
NOTIFY_ID=991049  # Fixed ID for dunstify to replace notifications (no spam)
# --- End Configuration ---

CACHE_BASE_PATH="$HOME/.cache"
LANG_SWITCHER_DIR="$CACHE_BASE_PATH/language_switcher"
SUPER_PRESSED_FILE="$LANG_SWITCHER_DIR/super_pressed_state"
LANGUAGES_FILE="$LANG_SWITCHER_DIR/languages_list"
BASE_LANGUAGES_FILE="$LANG_SWITCHER_DIR/base_languages"
SPACE_COUNT_FILE="$LANG_SWITCHER_DIR/space_press_count"

# Ensure cache directory and flag files exist (fast, no IPC)
_ensure_cache_dir() {
    mkdir -p "$LANG_SWITCHER_DIR"
    [[ -f "$SUPER_PRESSED_FILE" ]] || echo "false" > "$SUPER_PRESSED_FILE"
    [[ -f "$SPACE_COUNT_FILE" ]] || echo "0" > "$SPACE_COUNT_FILE"
}

# Fetch keyboard data from sway IPC (only needed by toggle_language)
_fetch_keyboard_data() {
    local current_inputs
    current_inputs=$(swaymsg -t get_inputs -r)
    json_data=$(echo "$current_inputs" | jq -r 'first(.[] | select(.type == "keyboard" and .xkb_layout_names)) // empty')

    if [[ -z "$json_data" ]]; then
        dunstify -u critical "Language Switcher" "No keyboard with xkb_layout_names found."
        exit 1
    fi

    identifier=$(echo "$json_data" | jq -r '.identifier')
    if [[ -z "$identifier" ]]; then
        dunstify -u critical "Language Switcher" "Could not get keyboard identifier."
        exit 1
    fi

    mapfile -t DEFAULT_LANGUAGES < <(echo "$json_data" | jq -r '.xkb_layout_names[]?' | tr ' ' '_')
    xkb_active_layout_index=$(echo "$json_data" | jq -r '.xkb_active_layout_index // "0"')

    if [[ ${#DEFAULT_LANGUAGES[@]} -eq 0 ]] || [[ -z "${DEFAULT_LANGUAGES[0]}" ]]; then
        dunstify -u critical "Language Switcher" "No layout names found for '$identifier'."
        exit 1
    fi

    if ! [[ "$xkb_active_layout_index" =~ ^[0-9]+$ ]] || [[ "$xkb_active_layout_index" -ge "${#DEFAULT_LANGUAGES[@]}" ]]; then
        xkb_active_layout_index=0
    fi
}

# Initialize languages cache file if missing (needs sway data)
_init_languages_cache() {
    if [[ ! -f "$LANGUAGES_FILE" ]]; then
        if [[ ${#DEFAULT_LANGUAGES[@]} -gt 0 ]]; then
            local active="${DEFAULT_LANGUAGES[$xkb_active_layout_index]}"
            local ordered=("$active")
            for lang in "${DEFAULT_LANGUAGES[@]}"; do
                [[ "$lang" != "$active" ]] && ordered+=("$lang")
            done
            echo "${ordered[*]}" > "$LANGUAGES_FILE"
        fi
    fi
}

# Format and show notification: [active] - next - rest
_notify_layout() {
    local -a langs=("$@")
    local display=""
    for i in "${!langs[@]}"; do
        if [[ $i -eq 0 ]]; then
            display="[${langs[$i]}]"
        else
            display+=" - ${langs[$i]}"
        fi
    done
    dunstify -r "$NOTIFY_ID" -t 1500 "Keyboard" "$display"
}

# Swap first two elements of array (passed by nameref)
_swap_first_two() {
    local -n ref=$1
    if [[ ${#ref[@]} -ge 2 ]]; then
        local tmp="${ref[0]}"
        ref[0]="${ref[1]}"
        ref[1]="$tmp"
    fi
}

# Rotate left: move first element to end
_rotate_left() {
    local -n ref=$1
    if [[ ${#ref[@]} -ge 2 ]]; then
        local first="${ref[0]}"
        ref=("${ref[@]:1}" "$first")
    fi
}

# Find the system index for a layout name and apply it
_apply_layout() {
    local target="$1"
    shift
    local -a langs=("$@")

    local idx=-1
    for i in "${!DEFAULT_LANGUAGES[@]}"; do
        if [[ "${DEFAULT_LANGUAGES[$i]}" == "$target" ]]; then
            idx=$i
            break
        fi
    done

    if [[ "$idx" -eq -1 ]]; then
        dunstify -u critical -r "$NOTIFY_ID" "Language Switcher" "Layout '$target' not found in system layouts."
        return 1
    fi

    if swaymsg input "$identifier" xkb_switch_layout "$idx"; then
        echo "${langs[*]}" > "$LANGUAGES_FILE"
        _notify_layout "${langs[@]}"
    else
        dunstify -u critical -r "$NOTIFY_ID" "Language Switcher" "swaymsg failed to switch to '$target'."
        return 1
    fi
}

# --- Public functions (called from sway keybindings) ---

press_super() {
    _ensure_cache_dir
    echo "true" > "$SUPER_PRESSED_FILE"
    echo "0" > "$SPACE_COUNT_FILE"
}

release_super() {
    _ensure_cache_dir
    echo "false" > "$SUPER_PRESSED_FILE"
}

toggle_language() {
    _ensure_cache_dir
    _fetch_keyboard_data
    _init_languages_cache

    local super_is_pressed
    super_is_pressed=$(<"$SUPER_PRESSED_FILE")
    local space_count
    space_count=$(<"$SPACE_COUNT_FILE")

    local languages_str
    languages_str=$(<"$LANGUAGES_FILE")
    local langs
    read -r -a langs <<< "$languages_str"
    local num=${#langs[@]}

    # Recover from empty cache
    if [[ $num -eq 0 ]]; then
        if [[ ${#DEFAULT_LANGUAGES[@]} -gt 0 ]]; then
            local active="${DEFAULT_LANGUAGES[$xkb_active_layout_index]}"
            langs=("$active")
            for lang in "${DEFAULT_LANGUAGES[@]}"; do
                [[ "$lang" != "$active" ]] && langs+=("$lang")
            done
            echo "${langs[*]}" > "$LANGUAGES_FILE"
            num=${#langs[@]}
        else
            dunstify -u critical -r "$NOTIFY_ID" "Language Switcher" "No languages available."
            return 1
        fi
    fi

    if [[ $num -le 1 ]]; then
        _notify_layout "${langs[@]}"
        return 0
    fi

    if [[ "$super_is_pressed" == "true" ]]; then
        space_count=$((space_count + 1))
        echo "$space_count" > "$SPACE_COUNT_FILE"

        if [[ "$space_count" -eq 1 ]]; then
            # First press with super held: swap (correct for single-press toggle)
            # Save base state for cycling calculation on subsequent presses
            echo "${langs[*]}" > "$BASE_LANGUAGES_FILE"
            _swap_first_two langs
        else
            # 2nd+ press: compute from saved base state using pure rotation
            if [[ -f "$BASE_LANGUAGES_FILE" ]]; then
                read -r -a langs < "$BASE_LANGUAGES_FILE"
            fi
            local rotations=$((space_count % num))
            for ((i=0; i<rotations; i++)); do
                _rotate_left langs
            done
        fi
    else
        # No super held: simple swap first two
        _swap_first_two langs
    fi

    _apply_layout "${langs[0]}" "${langs[@]}"
}

# --- Dispatch ---
case "${1-}" in
    press_super|release_super|toggle_language) "$@" ;;
    *) echo "Usage: $0 {press_super|release_super|toggle_language}"; exit 1 ;;
esac
