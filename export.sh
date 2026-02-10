#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo "Archiving Song Manager..."
xcodebuild archive \
  -project "Song Manager.xcodeproj" \
  -scheme "Song Manager" \
  -archivePath "build/Song Manager.xcarchive" \
  -quiet

echo "Exporting app..."
xcodebuild -exportArchive \
  -archivePath "build/Song Manager.xcarchive" \
  -exportPath Export \
  -exportOptionsPlist ExportOptions.plist

echo "Copying to Dropbox..."
cp -R "Export/Song Manager.app" "/Users/aiden/Dropbox/music/aidenel songs/"
xattr -cr "/Users/aiden/Dropbox/music/aidenel songs/Song Manager.app"

echo "Done! App exported to: $PROJECT_DIR/Export/Song Manager.app"
