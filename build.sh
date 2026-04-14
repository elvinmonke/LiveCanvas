#!/bin/bash
set -e
echo "Generating Xcode project..."
xcodegen generate
echo "Building LiveCanvas..."
xcodebuild -project LiveCanvas.xcodeproj -scheme LiveCanvas -configuration Release build
echo "Done! App is in build/Release/LiveCanvas.app"
