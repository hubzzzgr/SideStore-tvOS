# SideTVstore

**Your apps. On the big screen.**

SideTVstore is a fork of [SideStore](https://github.com/SideStore/SideStore) that lets you install and manage compatible tvOS apps on your Apple TV directly from your iPhone over local Wi-Fi.

It retains SideStore's Apple ID sign-in, app signing, IPA management, and familiar interface, but replaces the usual iPhone pairing/VPN connection with a direct connection to a paired Apple TV. Once SideTVstore is installed on your iPhone, you can manage your Apple TV apps without a computer or LocalDevVPN for everyday use.

**[Download the IPA](https://github.com/hubzzzgr/SideStore-tvOS/releases/)** · [Release notes](https://github.com/hubzzzgr/SideStore-tvOS/releases)

## Screenshots

<p align="center">
  <img src="docs/images/apple-tv-setup.jpg" width="250" alt="SideTVstore Apple TV setup, ready-to-install status, and saved TV" />
  <img src="docs/images/apple-tv-pairing.jpg" width="250" alt="Nearby Apple TV discovery and pairing-file import and export" />
  <img src="docs/images/my-apps.jpg" width="250" alt="My Apps showing installed Apple TV apps, icons, expiry dates, and upload progress" />
</p>

## Features

- **Pair over Wi-Fi:** Discover nearby Apple TVs, enter the code shown on the TV, and save the pairing for automatic reconnection. You can also enter the TV's IP address if discovery doesn't find it.
- **Set up developer access automatically:** SideTVstore runs the TVPair developer-trust procedure and checks that the required services respond before allowing installation.
- **Install and manage tvOS IPAs:** Import an IPA, sign it with your Apple ID or an imported signing certificate, and install, update, refresh, or uninstall it on the selected Apple TV.
- **Manage installed apps:** View app artwork, signing expiration dates, and refresh controls in **My Apps**.
- **Import and export pairing files:** Back up or restore a saved Remote Pairing plist through Files. Saved credentials remain in your iPhone's Keychain. **Exported pairing files contain private credentials; keep them secure and don't share them.**
- **Track upload progress:** View upload status and transferred byte counts during installation.
- **Use with LiveContainer:** SideTVstore has also been tested inside LiveContainer; compatibility may vary by setup.

## Getting started

1. **Install the iPhone controller.** Download `SideTVstore-unsigned.ipa` from [Releases](https://github.com/hubzzzgr/SideStore-tvOS/releases). Sign and install it using your preferred iPhone installation method, or import it into a configured LiveContainer setup. This is an **iPhone app, not a tvOS app**; iOS cannot directly install an unsigned IPA.
2. **Connect both devices.** Put your iPhone and Apple TV on the same local Wi-Fi network, and allow SideTVstore access to the local network.
3. **Prepare your Apple TV.** Open **Settings → Remotes and Devices → Remote App and Devices**.
4. **Pair with your Apple TV.** Open the **Apple TV** tab in SideTVstore, select your TV, and enter the on-screen pairing code. Wait until the app shows **Ready to Install**.
5. **Configure signing.** Sign in with your Apple ID under **Settings**, or configure an imported signing certificate.
6. **Install an app.** In **My Apps**, tap **+** and select a decrypted, device-compatible **tvOS IPA**.

## Tested setup

SideTVstore has been tested on a physical iPhone running **iOS 27.0**, installing apps on a physical Apple TV running **tvOS 27.2**. It has also worked inside LiveContainer in the developer's setup. The screenshots above come from this testing.

These results reflect one tested configuration, not a guarantee for every iPhone, Apple TV, firmware version, or LiveContainer setup. The iPhone app targets **iOS 17 or later**; other combinations still need testing.

## Building

The [GitHub Actions workflow](https://github.com/hubzzzgr/SideStore-tvOS/actions/workflows/tvos-iphone.yml) produces an unsigned arm64 IPA for physical iPhones on a macOS runner. CI does not require paid Apple Developer credentials, but that does not remove the signing requirements for installing and using the app.

To build locally on macOS with Xcode 26.3 or newer:

```sh
git submodule update --init --recursive
xcodebuild -project AltStore.xcodeproj -scheme SideStore -configuration Release \
  -destination 'generic/platform=iOS' -sdk iphoneos ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
```