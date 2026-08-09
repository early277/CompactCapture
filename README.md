# CompactCapture

**English** | [日本語](README_ja.md)

CompactCapture is an iPhone and iPad camera app that gives you direct control over resolution, color detail, contrast, video bitrate, and storage-oriented capture settings.

The interface is available in English and Japanese.

## Key features

- Photos in PNG, JPEG, or HEIF, from the device's maximum resolution down to 0.025 MP
- Video in HEVC or H.264, plus ProRes 4444 on supported devices, from 4K down to 160 × 90
- Adjustable color detail, contrast, compression quality, and video bitrate
- Nearest-neighbor integer scaling for crisp low-resolution pixels
- Manual ISO, shutter speed, exposure compensation, and white balance controls
- Device-aware zoom presets from 0.5× up to 15×, plus pinch-to-zoom
- Named capture presets
- Built-in photo and video library with optional export to the system Photos app
- Portrait-first interface, with previews kept upright if iPadOS resizes or rotates the scene
- Capture orientation stored correctly in saved photos and videos

See [README_ja.md](README_ja.md) for the complete feature reference and detailed build notes.

## Requirements

- iOS / iPadOS 17.0 or later
- Xcode 16 or later recommended
- A physical device is required to test camera capture

## Open the project

1. Open `CompactCapture.xcodeproj` in Xcode.
2. Select your own Team under Signing & Capabilities.
3. Change the Bundle Identifier if it conflicts with an existing app identifier.
4. Build and run on a physical iPhone or iPad.

No Apple Developer Team ID, provisioning profile, signing certificate, or Xcode user data is included in this repository.

## Privacy

Read the [Privacy Policy](PRIVACY_POLICY.md) or [プライバシーポリシー](PRIVACY_POLICY_ja.md).

## Support

Read [Support](SUPPORT.md) or [サポート](SUPPORT_ja.md). Questions and bug reports are accepted through GitHub Issues.

## License

This project is available under the [MIT License](LICENSE).
