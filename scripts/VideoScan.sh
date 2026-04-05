#!/bin/bash

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Activate the venv relative to the script
VENV="$SCRIPT_DIR/venv"

if [ ! -d "$VENV" ]; then
    echo "ERROR: No venv found at $VENV"
    echo "Run: python3 -m venv venv && source venv/bin/activate && pip install openpyxl"
    exit 1
fi

source "$VENV/bin/activate"

# Check openpyxl is available, install if missing
python3 -c "import openpyxl" 2>/dev/null || {
    echo "openpyxl not found, installing..."
    pip install openpyxl
}

# Run the catalogue script, passing through any arguments
python3 "$SCRIPT_DIR/VideoScan.py" "$@"
