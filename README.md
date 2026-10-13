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

## Public snapshot and submitted build

This repository is the October 8, 2026 source snapshot. It predates the iOS
1.0 TestFlight/App Review build `202610092221` made on October 9, which includes
a later task-board freshness change. Do not treat this snapshot's simulator
results as validation of that submitted binary. The current review state and
the separate simulator/physical-device evidence are listed on the
[Quotient status page](https://scott987-cmd.github.io/quotient/app-store-readiness.html).
