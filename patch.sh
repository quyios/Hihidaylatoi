#!/bin/bash

# FULL PATCH VERSION
# Restored with dylib injection and ElleKit bundling

set -e

IPA_NAME=$1
DYLIB_NAME="ADManagerRotation.dylib"
BINARY_PATH="Payload/ADManager.app/ADManager"
NEW_IPA="ADManager_Patched.ipa"

if [ -z "$IPA_NAME" ]; then
    echo "Usage: $0 <input.ipa>"
    exit 1
fi

echo "Unzipping IPA..."
unzip -q "$IPA_NAME"

echo "Fixing permissions for binaries..."
chmod +x "Payload/ADManager.app/ADManager"
chmod +x "Payload/ADManager.app/fastPathSign"

# 1. Compile insert_dylib if not present
if [ ! -f "./insert_dylib" ]; then
    echo "Compiling insert_dylib from source..."
    git clone https://github.com/Tyilo/insert_dylib.git insert_dylib_src
    clang insert_dylib_src/insert_dylib/main.c -o insert_dylib
    rm -rf insert_dylib_src
    chmod +x insert_dylib
fi

# 2. Inject the dylib into the binary
echo "Injecting dylib..."
./insert_dylib --inplace --all-yes "@executable_path/$DYLIB_NAME" "$BINARY_PATH"

# 3. Copy dylib into app bundle
echo "Copying dylib into app bundle..."
cp "$DYLIB_NAME" "Payload/ADManager.app/"

# 4. Bundle ElleKit for TrollStore compatibility
echo "Bundling ElleKit..."
curl -L https://github.com/evelyneee/ElleKit/releases/latest/download/ElleKit.dylib -o ElleKit.dylib
cp ElleKit.dylib "Payload/ADManager.app/"

# 5. Fix load commands to point to our local ElleKit
echo "Fixing load paths..."
install_name_tool -change /usr/lib/libsubstrate.dylib @executable_path/ElleKit.dylib "Payload/ADManager.app/$DYLIB_NAME" || true
install_name_tool -change /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate @executable_path/ElleKit.dylib "Payload/ADManager.app/$DYLIB_NAME" || true

# 6. Sign everything with codesign (macOS native)
echo "Re-signing modified components..."
codesign -s - --force "Payload/ADManager.app/ElleKit.dylib"
codesign -s - --force "Payload/ADManager.app/$DYLIB_NAME"
# Re-sign the main binary to update the code signature header after injection
codesign -s - --force "Payload/ADManager.app/ADManager"
codesign -s - --force "Payload/ADManager.app/fastPathSign"

echo "Repackaging IPA..."
# -y is critical for symlinks, -q for quiet
zip -qry "$NEW_IPA" Payload

echo "Done! Patched IPA: $NEW_IPA"
rm -rf Payload

