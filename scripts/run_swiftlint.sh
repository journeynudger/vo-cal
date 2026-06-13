#!/bin/bash
# Wrapper to run swiftlint with the correct DEVELOPER_DIR if xcode-select is misconfigured.
# This fixes "Loading sourcekitdInProc.framework failed" errors when xcode-select points to CommandLineTools.

# If DEVELOPER_DIR is already set by the user/system, trust it.
if [ -z "$DEVELOPER_DIR" ]; then
    CURRENT_PATH=$(xcode-select -p)

    # If active path points to CommandLineTools (which lacks SourceKit frameworks)...
    if [[ "$CURRENT_PATH" == *"/CommandLineTools" ]]; then
        # Try to find standard Xcode installations
        if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
            export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        elif [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
            export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
        fi
    fi
fi

# Execute swiftlint with passed arguments
exec swiftlint "$@"
