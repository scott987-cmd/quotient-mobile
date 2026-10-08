# Security

Please report suspected vulnerabilities privately to the repository owner
before posting details publicly. Do not include API keys, signing identities,
device identifiers, task prompts, or unredacted simulator logs in an issue.

The app reads data from a user-configured shared directory and writes explicit
actions back for the Mac coordinator. It should never turn an unknown or stale
source into an actionable confirmation. Physical-device APNs and iCloud behavior
must be checked separately from simulator tests.
