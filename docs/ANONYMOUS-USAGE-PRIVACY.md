# Anonymous usage count

This feature is deferred from version 4.5. The first-launch choice and General
Settings control are absent, and the reporting client is disabled even if a
previous build saved consent or an endpoint is configured. This document retains
the design requirements for a future release.

When reintroduced, the app must ask before enabling its anonymous usage count.
The initial choice must have no selected default. Choosing **Don't send data**
must make no network request. This feature is separate from quality analysis and
does not collect conversion analytics.

If enabled, the app creates a random 32-byte installation secret in the
device-only macOS Keychain. With a configured endpoint, it derives a
new HMAC-SHA256 token for each ISO calendar week. The secret never leaves the
Mac. When the app opens, it may send `{"token":"<weekly token>"}` by HTTPS,
at most once in a rolling 24-hour period. A failed attempt is not retried
until the next period. Turning reporting off cancels an in-progress request,
removes the Keychain secret, and clears the local send date.

The payload has no filenames, paths, media or conversion details, account
information, hardware identifiers, or OS metadata. The app disables cookies,
uses a fixed user agent, and does not follow redirects for this request. A
week's token can be used to count distinct **active installations**, not
people: one person may use several Macs, and a Mac may be shared.

## Endpoint requirements before activation

The dormant client can read an `AnonymousUsageEndpoint` HTTPS URL from its app
bundle, but the 4.5 release gate prevents reporting regardless of that value.
Before a future release enables reporting, the server must be implemented and
reviewed to assign the receipt date and week, store only data required for
seven-day distinct-installation counts, avoid retaining client IP addresses
in application and proxy logs, and publish a retention schedule and the
public privacy policy. Counts must be described as active installations.
Weekly rotation prevents exact deduplication across a week boundary in a
rolling seven-day window; the public metric must either use calendar-week
counts or disclose this possible overcount.
