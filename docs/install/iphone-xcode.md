# Install the app on iPhone with Xcode

[Deutsch](de/iphone-xcode.md) · [Back to downloads](../../README.md#iphone)

For Mac users with Xcode: a script builds the app on your Mac and installs it on the connected iPhone. No AltStore needed.

**File:** `Remote-for-ADI-2-iPhone-Xcode-1.3.0.zip` from the [iPhone download section](../../README.md#iphone).
**Requires:** Mac with Xcode (free in the App Store) and about 5 GB free space, an Apple ID (a free one is enough), iPhone with iOS 15 or later and a USB cable. The first run takes about 15–30 minutes, later runs a few minutes.

## One-time setup

1. Open Xcode once and install the offered components, including **iOS**.
2. **Xcode → Settings → Accounts → +** → Apple Account → sign in. Select your team → **Manage Certificates…** → **+** → **Apple Development**.
3. Connect the iPhone by USB, unlock it and tap **Trust This Computer**.
4. On the iPhone (iOS 16 or later): **Settings → Privacy & Security → Developer Mode** → on, restart, confirm **Turn On**.
5. Flutter: the script offers to download it to `~/development/flutter` (about 1.5 GB) on the first run. Alternatively install it beforehand with `brew install --cask flutter`.

## Install

1. Unzip the file.
2. Right-click **Installieren.command** → **Open** → **Open**. (Only needed the first time; if macOS still blocks it: **System Settings → Privacy & Security → Open Anyway**.)
3. A Terminal window shows steps 1/6 to 6/6. If macOS asks for the keychain password, enter your Mac password and choose **Always Allow**.
4. First time on the iPhone: **Settings → General → VPN & Device Management** → your Apple ID → **Trust**. Then open **Remote for ADI-2**.

## Good to know

- With a free Apple ID the app runs for **7 days**; then connect the iPhone and run the script again. Settings are kept. With a paid developer account it runs for one year.
- New version: unzip the new package and run **Installieren.command** again.
- If the build fails, details are in `build/xcodebuild.log`; please attach it to an [issue](https://github.com/kahuna34/remote-for-ADI-2/issues).
- Connecting the ADI-2: see [iPhone with AltStore → Connect the ADI-2](iphone-altstore.md#connect-the-adi-2).
