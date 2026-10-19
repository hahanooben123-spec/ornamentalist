# First TestFlight upload from iPad

Team ID: `K2TYPDPPZJ`. Bundle ID: `studie.mandala.prototype`.

Apple supports uploading app playgrounds directly from Swift Playgrounds on
iPad. This is our first-upload path; no GitHub API key or Mac is required.
The signed upload has not yet been verified with this Apple account.

1. Pull `main` in the iPad Git app. Open **Ornamentalist.swiftpm** in Swift
   Playgrounds and run the app once.
2. Open **App Settings** in Swift Playgrounds. Sign in with your enrolled Apple
   Account and select Christian Mortensen's team (`K2TYPDPPZJ`). Keep the Bundle
   ID above and the project version/build, choose the icon and category, then
   tap **Upload to App Store Connect**. If an app record is requested, use
   **Ornamentalist**, English and SKU `ornamentalist-ipad`.
3. After Apple processes the build, open **App Store Connect → Apps →
   Ornamentalist → TestFlight**. Complete any export-compliance questions and
   create an internal test group containing your own account. Add the processed
   build and accept the invitation in TestFlight on your iPad.

If an app record must be created separately, register an explicit App ID for
that Bundle ID in Apple Developer, then create the iOS app in App Store Connect.
The team, Bundle ID and app record must match.

Uploading does not publish a public App Store release. External testing may
require Beta App Review. If upload fails, inspect the actual error before
retrying. A source package check does not confirm Apple acceptance.

Privacy policy:
https://hahanooben123-spec.github.io/ornamentalist-website/privacy.html

Contact: Christian Mortensen — Chrismortensen1997@outlook.dk.

## Privacy manifest

`Resources/PrivacyInfo.xcprivacy` declares local preferences, file timestamps
for app-managed/user-selected files and elapsed-time measurements for autosave
and rendering. It declares no tracking or collected data. It is separate from
the hosted policy and App Store Connect's privacy questionnaire.

References:
- https://support.apple.com/guide/playgrounds-ipad/share-a-playground-itc65b2d9a15/ipados
- https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds
- https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
