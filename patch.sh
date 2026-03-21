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

echo "Injecting dylib..."
# Compile insert_dylib if not present
if [ ! -f "./insert_dylib" ]; then
    echo "Compiling insert_dylib from source..."
    git clone https://github.com/Tyilo/insert_dylib.git
    clang insert_dylib/insert_dylib/main.c -o insert_dylib
    rm -rf insert_dylib
    chmod +x insert_dylib
fi

# Inject the dylib into the binary
# We use @executable_path to ensure it loads from the same folder
./insert_dylib --append --all-yes "@executable_path/$DYLIB_NAME" "$BINARY_PATH"

echo "Copying dylib into app bundle..."
cp "$DYLIB_NAME" "Payload/ADManager.app/"

echo "Repackaging IPA..."
NEW_IPA="ADManager_Patched.ipa"
zip -qr "$NEW_IPA" Payload

echo "Done! Patched IPA: $NEW_IPA"
rm -rf Payload

