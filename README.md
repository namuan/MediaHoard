# MediaHoard

A SwiftUI iOS app for resolving supported media links, downloading files to the app's Documents area, and sharing or playing completed downloads.

## Build and install on a device

Install Xcode with iOS platform support and XcodeGen (`brew install xcodegen`). Connect and unlock an iPhone or iPad, enable Developer Mode on it, and accept the computer trust prompt. Sign in to Xcode with an Apple ID that can sign development builds, register the device with that team, and ensure provisioning is enabled. The Makefile attempts to detect a team from local Xcode configuration or a development certificate; detection can be overridden with `TEAM_ID=...`. Automatic provisioning requires the Apple ID to be added under Xcode Settings → Accounts.

Run this single command from the project directory:

```sh
make deploy
```

The command generates the Xcode project, resolves YouTubeKit through Swift Package Manager, detects the connected iOS device and development team, builds with automatic provisioning, installs, and launches the app. Override detection with `make deploy DEVICE_ID=<device-identifier> TEAM_ID=<team-id>`. No TestFlight or App Store distribution is involved. A free Apple ID's development provisioning may expire and require rebuilding/reinstalling.

If Xcode reports `No Account for Team`, add the Apple ID under Xcode Settings → Accounts and run the app on the device once from Xcode to create a provisioning profile. Keep the iPhone connected, unlocked, trusted, and in Developer Mode.

## Current scope

Direct links are accepted when they use HTTPS and have a recognized media extension. YouTube resolution uses the locally configured YouTubeKit package version and intentionally does not enable the package's remote fallback. YouTube extraction is best effort and can stop working when the service changes or restricts content. Only standalone audio streams or progressive streams containing both audio and video are offered; separate tracks are not muxed.

Only download media when you have the rights and permission to do so and use complies with applicable laws and service terms. The app keeps completed originals in its Application Support library and exposes them in Documents/Downloads for Files access. It shares a temporary copy so sharing cannot remove the library original. Downloads currently run only while the app is active and are not resumable.

## License

See [LICENSE](LICENSE).
