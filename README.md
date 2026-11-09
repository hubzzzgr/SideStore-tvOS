# SideTVstore — iPhone controller for Apple TV

Experimental SideStore fork for signing and managing tvOS IPAs over local Wi-Fi, using the Apple TV pairing procedure from [TVPair](https://github.com/hubzzzgr/tvOS-pairtest). No LocalDevVPN or local loopback VPN dependency.

[Setup, implementation and platform limits](docs/APPLE-TV.md) · [Unsigned iPhone IPA builds](https://github.com/hubzzzgr/SideStore-tvOS/actions/workflows/tvos-iphone.yml)

**Physical Apple TV installation has not yet been validated. A build or successful pairing does not establish installation support.** See the hardware acceptance checklist and service restrictions before testing. The controller requires iOS 17+; CI uses no paid Apple Developer credentials. Runtime Apple account provisioning permissions still apply.

The inherited authentication, signing, IPA cache and relevant My Apps/Settings UI remain in this repository. Development changes are on the `tvos` branch. SideStore's AGPL-3.0 license and attribution are preserved.


Build locally on macOS with Xcode 26.3 or newer:

```sh
git submodule update --init --recursive
xcodebuild -project AltStore.xcodeproj -scheme SideStore -configuration Release \
  -destination 'generic/platform=iOS' -sdk iphoneos ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
```

Based on [SideStore](https://github.com/SideStore/SideStore), originally forked from [AltStore](https://github.com/altstoreio/AltStore). Original authorship and licenses remain intact.
