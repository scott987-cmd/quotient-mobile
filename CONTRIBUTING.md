# Contributing

Generate the Xcode project with XcodeGen, then run the complete iPhone unit and
UI suite. UI or navigation changes should also be checked on iPad. Keep test
data isolated from real iCloud and task boards. Do not use a green simulator
result as evidence that APNs or cross-device iCloud propagation works.

Shared Mac/iOS protocol fields must tolerate missing older fields and unknown
enum values. Changes to confirmations and writes need tests for source-machine
routing, stale data, retries, and successful receipts.
