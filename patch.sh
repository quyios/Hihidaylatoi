#!/bin/bash
set -e
IPA_NAME=$1
DYLIB_NAME="ADManagerRotation.dylib"
BINARY_PATH="Payload/ADManager.app/ADManager"

echo "Unzipping IPA..."
unzip -q "$IPA_NAME"
chmod +x "$BINARY_PATH"

echo "Compiling insert_dylib..."
git clone https://github.com/Tyilo/insert_dylib.git insert_dylib_src
clang insert_dylib_src/insert_dylib/main.c -o insert_dylib
chmod +x insert_dylib

echo "Injecting dylib..."
./insert_dylib --inplace --all-yes --no-strip-codesig "@executable_path/$DYLIB_NAME" "$BINARY_PATH"

echo "Copying dylib..."
cp "$DYLIB_NAME" "Payload/ADManager.app/"

echo "Repackaging IPA..."
zip -qry "ADManager_Patched.ipa" Payload
rm -rf Payload insert_dylib insert_dylib_src
echo "Done!"
