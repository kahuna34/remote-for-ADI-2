# Install the host on Windows

[Deutsch](de/host-windows.md) · [Back to downloads](../../README.md#download)

**File:** `Remote-for-ADI-2-Host-Windows-Setup-1.3.0.exe` from the [download section](../../README.md#download).
**Requires:** Windows PC (64-bit) with the ADI-2 connected by USB; for Wi-Fi control, both devices must be on the same network.

Remote for ADI-2 Host includes its own interface for controlling the ADI-2 on the computer and provides Wi-Fi control from a smartphone, tablet or another computer. For a direct USB connection to the phone, the app is enough.

## 1. Install

1. Run **Remote-for-ADI-2-Host-Windows-Setup-1.3.0.exe**. It installs for your user account without administrator rights, adds **Remote for ADI-2 Host** to the Start menu and switches on **Start with Windows**.
2. If SmartScreen warns, choose **More info → Run anyway**.
3. The icon appears in the notification area of the taskbar, possibly behind the arrow (^).
4. Allow **Private networks** when Windows Firewall asks. If access was granted only for Public networks, open **Windows Security → Firewall & network protection → Allow an app through firewall** and check **Private** for **Remote for ADI-2 Host**.

The host detects devices being connected or disconnected and opens a fresh MIDI connection for each session through a small helper program. It keeps running and its icon stays visible.

## Interface

A normal start opens the interface. The header offers **Desktop**, **Device only** and **Compact view**, plus separate analyzer and player windows. Details: [user guide](../USER_GUIDE.md#desktop-views-and-windows).

Closing the window keeps the host running in the background. Left-click the icon to open the interface; right-click for the menu. Starting the program again brings the running interface forward. Autostart through the icon menu starts only in the background. **Exit** in the menu quits the host.

## 2. Pair a smartphone or tablet

1. In the host menu choose **Pair client…**.
2. In the app choose **Connect via host** and scan the QR code or enter the code.
3. Up to four smartphones or tablets can be connected at the same time; pair each one once.

Details: [user guide](../USER_GUIDE.md#control-through-a-computer-host).

## Control another computer

On the other computer, start Remote for ADI-2 Host (Mac/Windows) or Remote for ADI-2 (Linux), connect the ADI-2 by USB and enable **MIDI Control → ON**. Both computers must be on the same network.

Choose **Pair client…** in that computer’s icon menu. On the controlling computer, use **HOST** or **CLIENT** to open **Connect via host**, select the other computer and enter its code. **HOST** is green for this computer; **CLIENT** is blue when connected to another host. The active connection is marked. **This computer** switches back to the local ADI-2.

## Updates and uninstalling

The host reports new versions (can be switched off). Run the new setup; pairings and settings are kept. Uninstall under **Settings → Apps → Installed apps**.

## Using an iPhone

AltServer from AltStore can run next to the host on the same PC; see [iPhone with AltStore](iphone-altstore.md).
