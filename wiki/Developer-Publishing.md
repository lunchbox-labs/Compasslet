# Publishing

For maintainers preparing App Store and TestFlight builds. [Publish](https://github.com/lunchbox-labs/compasslet/blob/main/.github/workflows/publish.yml)
runs only manually from `main`. Publishing a GitHub Release or merging a PR does
not run it. Configure both environments to allow only `main`, with the required
approvals, before running Publish; release tags do not need access. The workflow
does not configure credentials or permissions.

Each run uploads one of two kinds of build, chosen by its **Release candidate** box:

- **Unchecked (the default):** a test build for internal TestFlight testing only. App
  Store Connect won't let it be submitted for review or added to external testing
  groups, and Publish updates only its TestFlight copy, leaving the App Store listing
  alone. Its Settings screen ends with a Test Build section showing the version, build
  number and short commit SHA, so testers can tell exactly which build they have.
- **Checked:** a release candidate, eligible for both internal TestFlight testing and
  App Store submission. Publish also updates the App Store listing from its copy. It
  shows no Test Build section.

Check the box only for a build you're considering for an App Store release. A test
build can't become one later; run Publish again with the box checked. Publish does not
submit to App Review or release the app; select the processed release candidate and
submit it separately in App Store Connect.

## GitHub Releases and screenshots

After Apple approves a version, create its version tag and GitHub Release by hand.
Create the release as a draft against the approved version's commit.

To include screenshots:

1. Run the [Screenshots workflow](https://github.com/lunchbox-labs/compasslet/actions/workflows/screenshots.yml)
   manually with its `ref` input set to that version tag or commit.
2. Download the images from the run's `screenshots-run-<run number>` artifact.
   Images ending in `-part2`, `-part3` and so on show the rest of a screen that
   scrolls; leave them out, or set the run's `max-parts` input to 1 to capture only
   the top of each screen.
3. Attach the images to the draft GitHub Release, then publish it once all assets
   are in place.

Published releases are [immutable](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases):
assets cannot be added, replaced or deleted after publication. Attach screenshots
while the release is still a draft.

## App Store listing screenshots

Run the [Screenshots workflow](https://github.com/lunchbox-labs/compasslet/actions/workflows/screenshots.yml)
manually with `set` set to `listing` and `ref` set to the commit being submitted.
It captures the compass in light and dark on iPhone 17. Download
`iphone-17-light-compass.png` and `iphone-17-dark-compass.png` from the run's
`screenshots-run-<run number>` artifact (its `screenshots.json` describes the
captures and isn't uploaded), then upload both to the version's iPhone screenshots
in App Store Connect.

Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
list one required iPhone size, iPhone with Dynamic Island (medium display), which
iPhone 17 is. The app is iPhone only, so no iPad screenshots are needed
([#309](https://github.com/lunchbox-labs/compasslet/issues/309)). Apple Watch
([#304](https://github.com/lunchbox-labs/compasslet/issues/304)) and iPhone Duo
([#305](https://github.com/lunchbox-labs/compasslet/issues/305)) screenshots are
left out of the first release. Apple says iPhone Duo screenshots become required
from April 2027 for apps built with the iOS 27.1 SDK or later.

## Credentials and signing

Keep these key IDs as environment Variables and private keys as environment Secrets:

| Environment | Variable | Secret | Apple role |
| --- | --- | --- | --- |
| `app-store-publish` | `ASC_DEVELOPER_API_KEY_ID` | `ASC_DEVELOPER_API_PRIVATE_KEY_BASE64` | Developer for uploads |
| `app-store-metadata` | `ASC_METADATA_API_KEY_ID` | `ASC_METADATA_API_PRIVATE_KEY_BASE64` | App Manager for listing and TestFlight edits |

Private-key secrets contain base64-encoded `.p8` contents. Both team keys share
repository Variable `ASC_API_ISSUER_ID`; keep `APPLE_TEAM_ID` as a repository
Variable too. Match each key ID to its private key. Metadata has no fallback to
the upload key, and the upload script does not read the former `ASC_API_KEY_ID`
or `ASC_API_PRIVATE_KEY_BASE64` names. Verify the metadata key's actual role and
app access: successful build upload does not prove permission to edit listings.

The upload environment also needs these signing Secrets:

| Secret | Contents |
| --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | Base64 distribution certificate and private-key `.p12` |
| `IOS_DISTRIBUTION_P12_PASSWORD` | Password for that `.p12` |
| `IOS_APP_PROFILE_BASE64` | Base64 iPhone distribution profile |
| `IOS_ACTIVITY_PROFILE_BASE64` | Base64 Live Activity distribution profile |

Profiles must match the app's identifiers, entitlements and signing certificate,
including Apple's approved CarPlay capability. Never commit credential values.
GitHub uses a same-named repository secret if an environment secret is absent;
environment-only isolation therefore requires removing repository duplicates after
validating their replacements. Do not create a repository fallback for the metadata
private key. Both environments need to allow only `main`.

Keep original private keys securely: GitHub cannot reveal stored secret values and
Apple permits downloading a `.p8` only once. Moving storage does not require key
rotation. When replacing a key, validate its matching ID and secret before revoking
the old key.

## Release copy

Edit `app-store/<locale>/` before uploading the build that should use the copy.
The metadata job uses the uploaded commit, not newer edits on `main`.

| File | Destination | Limit |
| --- | --- | --- |
| `description.txt` | App Store description and app-wide TestFlight description | 4,000 characters |
| `promotional-text.txt` | App Store promotional text | 170 characters |
| `keywords.txt` | App Store keywords | 100 UTF-8 bytes |
| `whats-new.txt` | App Store release notes | 4,000 characters |
| `what-to-test.txt` | Uploaded TestFlight build's testing instructions | 4,000 characters |
| `name.txt` | App Store name | 30 characters |
| `subtitle.txt` | App Store subtitle | 30 characters |
| `privacy-policy-url.txt` | Privacy policy URL | One `https` URL, 2,000 characters |
| `privacy-choices-url.txt` | Privacy choices URL | One `https` URL, 2,000 characters |
| `support-url.txt` | Support URL | One `https` URL, 2,000 characters |
| `marketing-url.txt` | Marketing URL | One `https` URL, 2,000 characters |

Missing files leave fields unchanged; blank or overlong files fail validation.
The TestFlight description also affects existing beta builds. Release notes and
testing instructions are separate fields, never substituted for each other.

After upload, sync updates only supplied, changed fields in existing localizations.
Test builds update only the TestFlight description and testing instructions.
App Store edits require an existing editable iOS version matching the archive's
marketing version. Name, subtitle and privacy URLs belong to the app info record
rather than a version, and are updated only when exactly one app info is editable.
Review `UPDATED`, `UNCHANGED` and `SKIP` messages: missing or noneditable versions
and missing locales are skipped. Create any needed version or locale in App Store
Connect. Sync does not create resources, submit for review or distribute builds.

When testing instructions are supplied, sync waits up to about ten minutes for
the exact uploaded build to finish processing. A metadata failure does not undo
the accepted upload or earlier metadata edits. Check App Store Connect and the
job log before retrying. Re-run only the metadata job to retry the original build
and copy; re-running the entire workflow uploads another build of the same kind.
