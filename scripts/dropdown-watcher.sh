#!/bin/bash
swaymsg -t subscribe -m '["window"]' | while read -r event; do
    change=$(echo "$event" | jq -r '.change // empty')
    app_id=$(echo "$event" | jq -r '.container.app_id // empty')
    
    if [[ "$change" == "focus" ]] && [[ "$app_id" != "$termDropdown" ]]; then
        swaymsg '[app_id="dropdown-terminal"] move scratchpad' >/dev/null 2>&1
    fi
done
