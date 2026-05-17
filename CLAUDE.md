# Song Manager — project notes for Claude

## iOS deploy to physical device

CoreDevice / `devicectl` is unreliable on this machine — pairing tends
to fail with "broken pipe" on `dtfetchsymbols`. Use `ios-deploy`
(installed via `brew install ios-deploy`) which goes through the older
`libimobiledevice` stack and works reliably.

Build for device, then install:

```bash
cd "/Users/aiden/Software/Song Manager"

xcodebuild -project "Song Manager.xcodeproj" -scheme "Song Manager iOS" \
  -destination "generic/platform=iOS" -configuration Debug \
  -allowProvisioningUpdates build

ios-deploy --bundle "/Users/aiden/Library/Developer/Xcode/DerivedData/Song_Manager-eotmzyrsvotgbhcyhgwpeymxojhk/Build/Products/Debug-iphoneos/Song Manager iOS.app"
```

Free provisioning expires after 7 days. `-allowProvisioningUpdates`
lets xcodebuild auto-renew the profile in place; without it the build
fails with "No profiles for 'com.personal.Song-Manager.iOS' were
found." Re-trust the developer profile in Settings → General → VPN &
Device Management if iOS prompts for it.

## iOS deploy to simulator

```bash
cd "/Users/aiden/Software/Song Manager"

xcodebuild -project "Song Manager.xcodeproj" -scheme "Song Manager iOS" \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -configuration Debug build

APP="/Users/aiden/Library/Developer/Xcode/DerivedData/Song_Manager-eotmzyrsvotgbhcyhgwpeymxojhk/Build/Products/Debug-iphonesimulator/Song Manager iOS.app"
xcrun simctl install booted "$APP"
xcrun simctl terminate booted com.personal.Song-Manager.iOS 2>/dev/null
xcrun simctl launch booted com.personal.Song-Manager.iOS
```
