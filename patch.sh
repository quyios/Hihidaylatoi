#!/bin/bash
set -e

IPA_NAME=$1
DYLIB_NAME="ADManagerRotation.dylib"
BINARY_PATH="Payload/ADManager.app/ADManager"

if [ -z "$IPA_NAME" ]; then
    echo "Usage: $0 <input.ipa>"
    exit 1
fi

echo "Unzipping IPA..."
unzip -q "$IPA_NAME"

echo "Fixing binary permissions..."
chmod +x "Payload/ADManager.app/ADManager"
chmod +x "Payload/ADManager.app/fastPathSign"

# Compile insert_dylib if not present
if [ ! -f "./insert_dylib" ]; then
    echo "Compiling insert_dylib..."
    git clone https://github.com/Tyilo/insert_dylib.git insert_dylib_src
    clang insert_dylib_src/insert_dylib/main.c -o insert_dylib
    rm -rf insert_dylib_src
    chmod +x insert_dylib
fi

echo "Injecting dylib..."
./insert_dylib --inplace --all-yes "@executable_path/$DYLIB_NAME" "$BINARY_PATH"

echo "Copying dylib into app bundle..."
cp "$DYLIB_NAME" "Payload/ADManager.app/"

echo "Re-signing injected dylib..."
codesign -s - --force "Payload/ADManager.app/$DYLIB_NAME"
# NOTE: Do NOT re-sign ADManager binary - TrollStore handles that on install

echo "Repackaging IPA..."
zip -qry "ADManager_Patched.ipa" Payload
echo "Done!"
rm -rf Payload

