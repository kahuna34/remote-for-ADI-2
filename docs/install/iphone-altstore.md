# Install the app on iPhone with AltStore or SideStore

[Deutsch](de/iphone-altstore.md) · [Back to downloads](../../README.md#iphone)

The iPhone app is not in the App Store. AltStore and SideStore install it with your own Apple ID and sign it again regularly. A free Apple ID is enough.

**Files:** `Remote-for-ADI-2-iPhone-1.3.0.ipa` or the AltStore source from the [iPhone download section](../../README.md#iphone).
**Requires:** iPhone with iOS 15 or later, an Apple ID, a Mac or Windows PC for the one-time setup.

Good to know:

- With a free Apple ID the signature is valid for **7 days**. AltStore renews it automatically while AltServer runs on your computer and iPhone and computer are in the same Wi-Fi network. If it expires, the app no longer opens until it is refreshed; settings are kept.
- A free Apple ID allows **3 such apps** at the same time; AltStore or SideStore counts as one.
- In the EU, use **AltStore Classic** (with AltServer), not AltStore PAL.

## Option A: AltStore with AltServer (recommended)

AltServer runs in the background on your Mac or PC, like Remote for ADI-2 Host, and both can run side by side.

### 1. Install AltServer on the computer

1. Download AltServer from the official site **[altstore.io](https://altstore.io)**.
2. **Mac:** unzip the downloaded AltServer ZIP file, move **AltServer** to **Applications** and start it. Allow the permissions macOS asks for. The AltServer icon then appears at the top of the Mac's menu bar.
3. **Windows:** install AltServer with the setup. AltServer needs **iTunes** and **iCloud** from Apple's website (not the Microsoft Store versions). The icon appears in the notification area of the taskbar.
4. If anything differs, see the official instructions for [macOS](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) or [Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows).

### 2. Install AltStore on the iPhone

1. Connect the iPhone by USB, unlock it and tap **Trust This Computer**.
2. Mac: in Finder select the iPhone and switch on **Show this iPhone when on Wi-Fi**. Windows: in iTunes select the iPhone and switch on **Sync with this iPhone over Wi-Fi**. This enables refreshing over Wi-Fi.
3. Click the AltServer icon in the menu bar → **Install AltStore** → choose your iPhone and sign in with your Apple ID.
4. On the iPhone (iOS 16 or later): **Settings → Privacy & Security → Developer Mode** → on, restart, confirm **Turn On**.
5. **Settings → General → VPN & Device Management** → your Apple ID → **Trust**.

### 3. Install Remote for ADI-2

**With the source (updates appear in AltStore):**

1. Open AltStore → **Sources** → **+**.
2. Enter `https://raw.githubusercontent.com/kahuna34/remote-for-ADI-2/main/apps.json` and add it.
3. Open the source, choose **Remote for ADI-2** → **Free** / **Install**.

**Or with the IPA file:**

1. Download `Remote-for-ADI-2-iPhone-1.3.0.ipa` in Safari on the iPhone (it is saved in **Files → Downloads**).
2. AltStore → **My Apps** → **+** → choose the IPA.

### 4. Keep it running

AltStore refreshes the app in the background when AltServer is running and both are in the same Wi-Fi. You can also open AltStore → **My Apps** → **Refresh All**.

## Option B: SideStore

SideStore works like AltStore but refreshes the app directly on the iPhone, without a computer after the one-time setup. The setup is more technical (pairing file and a local VPN app). Follow the official guide at **[docs.sidestore.io](https://docs.sidestore.io)**, then add the source above under **Sources** or install the IPA under **My Apps → +**.

## Connect the ADI-2

- **Directly by USB:** iPhone with USB-C: USB-C cable to the ADI-2. iPhone with Lightning: Apple **Lightning to USB 3 Camera Adapter** (with power) plus a USB cable.
- On the ADI-2, switch on **MIDI Control** (DAC: **SETUP → Options → Remap Keys / Diag → MIDI Control**; Pro models: **SETUP → Options → Device Mode / DSD → MIDI Control**).
- **Over Wi-Fi:** through Remote for ADI-2 Host on [Mac](host-mac.md) or [Windows](host-windows.md), or [Remote for ADI-2 on Linux](linux.md).

iPhone specifics: the player bar shows Apple Music playing on the iPhone (or the host's player when connected via host). The iPhone's volume buttons control the ADI-2 when connected via host.
