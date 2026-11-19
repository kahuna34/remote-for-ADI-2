# Install the host on Windows

[Deutsch](de/host-windows.md) · [Back to downloads](../../README.md#download)

**File:** `Remote-for-ADI-2-Host-Windows-Setup-<version>.exe` from the [download section](../../README.md#download).
**Requires:** Windows PC (64-bit) with the ADI-2 connected by USB, smartphone/tablet and PC in the same network.

The host is only needed to control the ADI-2 over Wi-Fi through the computer. For a direct USB connection to the phone the app is enough.

## 1. Install

1. Run **Remote-for-ADI-2-Host-Windows-Setup-<version>.exe**. It installs for your user account without administrator rights, adds **Remote for ADI-2 Host** to the Start menu and switches on **Start with Windows**.
2. If SmartScreen warns, choose **More info → Run anyway**.
3. The icon appears in the notification area of the taskbar, possibly behind the arrow (^).
4. Allow **Private networks** when Windows Firewall asks. If access was granted only for Public networks, open **Windows Security → Firewall & network protection → Allow an app through firewall** and check **Private** for **Remote for ADI-2 Host**.

The host detects devices being connected or disconnected and opens a fresh MIDI connection for each session through a small helper program. It keeps running and its icon stays visible.

## 2. Pair a smartphone or tablet

1. In the host menu choose **Pair smartphone…**.
2. In the app choose **Connect via host** and scan the QR code or enter the code.
3. Up to four smartphones or tablets can be connected at the same time; pair each one once.

Details: [user guide](../USER_GUIDE.md#control-through-a-computer-host).

## Updates and uninstalling

The host reports new versions (can be switched off). Run the new setup; pairings and settings are kept. Uninstall under **Settings → Apps → Installed apps**.

## Using an iPhone

AltServer from AltStore can run next to the host on the same PC; see [iPhone with AltStore](iphone-altstore.md).
