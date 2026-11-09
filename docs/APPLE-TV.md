# SideStore TV controller fork

This is an experimental **iPhone application managing a remote Apple TV**.
It retains SideStore's Apple ID login, certificates, bundle IDs, signing,
IPA cache/import/export, app lists, and app operation pipeline. The iPhone
controller itself is not an app to install or refresh on the TV.

**A successful CI archive is not evidence of successful Apple TV installation.**
No physical Apple TV installation, refresh, update, or removal has been validated
by this implementation session. Hardware results from the pairing POC apply to
that POC and do not establish installation support in this fork.

## Setup and use

1. Download `SideStoreTV-unsigned-iphone-arm64` from the fork's Actions artifacts.
   Its IPA targets physical arm64 iPhones (iOS 17+). Sign/install the controller
   using your initial installation method. An unsigned IPA cannot be installed
   directly by iOS. CI needs no Apple ID, certificate, profile, or paid membership.
2. Put the iPhone and TV on the same LAN, allow Local Network access, and open
   **Settings → Remotes and Devices → Remote App and Devices** on Apple TV.
3. Open the **Apple TV** tab. Select a discovered TV or enter its numeric IP.
   Tap **Pair and enable developer access**, and enter the code displayed on TV.
   This automatically runs the POC's computer-host developer-trust procedure.
   There is no separate instruction to enable developer access manually when
   the procedure and subsequent developer-service checks succeed.
4. Wait for **Developer access and installation services verified**. Pairing,
   Keychain persistence, saved-record verification, TLS/CDTunnel, developer
   service response, and app-service availability are separate gates.
5. Sign in with your Apple ID in Settings. Registration uses the **TV UDID**
   read from authenticated RSD and device type **Apple TV**. Downloaded profiles
   request `subPlatform=tvOS`, and every profile must be unexpired, list `tvOS`,
   and include that TV's UDID. A valid certificate and matching entitlements are
   still required by SideStore's signer and by the device.
6. Import a decrypted, physical-device **tvOS IPA** with My Apps' add button or
   the iPhone share/open-in flow. The main executable and app extensions must
   identify AppleTVOS, arm64 and tvOS Mach-O load commands. Simulator, iPhone,
   and encrypted App Store binaries are rejected before signing/transfer.
7. My Apps retains install, source update, re-sign/reinstall from cache, profile
   refresh, and Delete App. **Remove from Library** only forgets local tracking.
   After install/uninstall, the device's app inventory must reflect the change.
   Cached packages are needed for re-signing. Existing external apps can be
   inspected in Apple TV → Read installed apps; this does not supply their IPAs.

## Transport and installation

The POC subset lives in `Packages/TVPairCore`, based on TVPair revision
`f483b5d444936181db93bf6fd2d6423bb28ca02b`. It includes DNS-SD discovery, targeted
unicast discovery, PIN setup, peer-signature verification, Keychain records,
TLS-PSK/CDTunnel, userspace TCP, RSD, and read-only developer probes. It excludes
incoming iPhone/iPad onboarding, record sharing UI, process suspension, process
termination, and all POC test-app controls.

New native clients implement the RSD two-reply check-in and:

| Service | Purpose and success condition |
| --- | --- |
| `com.apple.afc.shim.remote` | Real GetDeviceInfo probe, bounded file upload to a unique PublicStaging directory, cleanup and service FIN |
| `com.apple.mobile.installation_proxy.shim.remote` | Lookup probe; Install or Upgrade according to inventory; explicit Complete followed by inventory presence; Uninstall followed by inventory absence |
| `com.apple.misagent.shim.remote` | Provisioning-profile installation/removal; numeric zero status and profile inventory confirmation required for refresh success |

Service ports come exclusively from authenticated RSD. The fork never assumes
fixed app-service ports, and never sends pairing messages to AirPlay/Companion.
Operations are serialized because the POC's TCP router reads cooperatively.
The selected TV is locked for the duration of an operation group. Interrupted
mutations are not automatically replayed: inspect the TV's inventory before
explicitly retrying an uncertain install/uninstall. Progress reaching 100% is
not sufficient to report success.

Pairing private keys stay in Keychain with `WhenUnlockedThisDeviceOnly`; the
fork does not silently fall back to files or export keys in URL callbacks.
Reconnection refreshes Bonjour endpoint hints and verifies the pinned peer
identity. Changed IP addresses are accepted only after that verification.
Offline startup preserves credentials. Forgetting a record on the iPhone does
not revoke the computer-host trust stored on the TV.

The inherited library schema has no device key. To prevent cross-TV corruption,
one library is bound to one saved TV while it contains tracked apps. Remove
those records before switching TVs. Multiple pairing records may be kept, but
simultaneous per-TV app libraries are not implemented.

## Restrictions and remaining hardware validation

- The TV must expose the POC's Remote Pairing services and accept the on-screen
  code. Discovery names are unauthenticated hints. Client isolation, sleeping
  TVs, Bonjour filtering, or denied Local Network access can stop setup.
- Developer trust is not a universal developer-mode bypass. There is no separate
  tvOS Developer Mode switch asserted here. The fork verifies an actual
  Instruments or CoreDevice read-only response before any installation attempt.
- Availability of the three RSD shim services on the particular tvOS build is
  unverified. Missing/denied services stop explicitly. A CoreDevice-only app
  installation protocol is not implemented as a guessed fallback.
- Some firmware requires a compatible or personalized Developer Disk Image.
  Automatic DDI download, personalization and mounting are not implemented.
  If the POC bootstrap does not expose a responding developer service, setup
  stops and reports the missing capability; it does not claim activation.
- Apple account/team permissions, device limits, profile expiry and entitlement
  restrictions still apply. Free-account tvOS profile issuance must be tested
  with the user's account; this fork does not promise Apple will issue it.
  The absence of paid CI credentials does not waive runtime provisioning rules.
- Signing private keys are not embedded in TV app payloads. Local anisette is enforced. Its libraries may be downloaded once during
  initial setup and then reused from protected app storage. There is no runtime
  anisette/signing/install relay server. Apple's authentication/provisioning
  services still require Internet access, as do optional source/IPA downloads.
- iOS background execution is opportunistic. Keep the controller foregrounded
  and the TV awake for initial testing. Automatic unattended seven-day refresh
  is not guaranteed. iPhone self-refresh, VPN setup, JIT/process controls, and
  SideBackup/helper-extension packaging are excluded from the TV experience.
- LiveContainer guest Keychain and Local Network access depend on its host.
  A successful standalone build does not establish LiveContainer compatibility.

Before claiming support, record both device models/OS versions and verify:
fresh PIN setup → saved-record reconnect after app/TV restarts and DHCP change →
live developer and installation probes → Apple TV portal registration/profile
issuance → signed install and actual launch on TV → same-ID update preserving
data → profile refresh followed by launch → uninstall and inventory absence.
Also exercise TV rejection, incorrect PIN, no free storage, expired/wrong-TV
profile, denied services, transfer cancellation, and Wi-Fi loss during install.
Logs or screenshots shared for validation must omit credentials and UDIDs.

## Build and source

The `Build Apple TV controller IPA` workflow runs on GitHub-hosted `macos-15`.
It verifies the upstream OpenSSL binary checksum, runs native protocol tests,
archives `generic/platform=iOS` with `ARCHS=arm64` and signing disabled, strips
distributor signatures from the packaged copy, and uploads the IPA, SHA-256 and
diagnostic logs. It never exports with an Apple provisioning profile. The
retained SideSign submodule is pinned; SwiftPM locks record source revisions.

Source licenses remain AGPL-3.0 for SideStore, MIT for the adapted TVPair code,
and the bundled third-party notices for BigInt/OpenSSL and protocol references.
Complete corresponding fork source is published at
https://github.com/hubzzzgr/SideStore-tvOS/tree/tvos.
