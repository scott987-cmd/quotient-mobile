# Quotient Mobile

This is the iOS companion for Quotient Core. It displays quota, work, questions,
and review state published by your own Macs. This source snapshot contains no
Apple signing identity, private iCloud data, task ledger, or QA recordings.

## Build for the simulator

Requirements: Xcode 26.6 with an iOS 26 simulator and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project LLMQuotaApp.xcodeproj -scheme LLMQuotaApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`project.yml` uses an example bundle identifier and disables signing. To use a
physical device, TestFlight, APNs, or your own iCloud data, configure your own
Apple team, unique bundle identifier, entitlements, and signing. A simulator
test does not validate those production services.

The Mac core and its protocol are maintained separately. Older records omit
some fields; keep backward-compatible decoding when changing shared data.
