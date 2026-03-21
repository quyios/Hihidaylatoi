#!/bin/bash

# MINIMAL DIAGNOSTIC VERSION
# To check if basic repackaging on GitHub is causing the crash

set -e

IPA_NAME=$1
NEW_IPA="ADManager_Patched.ipa"

if [ -z "$IPA_NAME" ]; then
    echo "Usage: $0 <input.ipa>"
    exit 1
fi

echo "Unzipping IPA..."
unzip -q "$IPA_NAME"

echo "Fixing permissions for binaries..."
# Ensure execution permissions for the main binary and the fastPathSign helper
chmod +x "Payload/ADManager.app/ADManager"
chmod +x "Payload/ADManager.app/fastPathSign"

echo "Repackaging IPA..."
# -y is critical for symlinks, -q for quiet
zip -qry "$NEW_IPA" Payload

echo "Done! Diagnostic IPA: $NEW_IPA"
rm -rf Payload

