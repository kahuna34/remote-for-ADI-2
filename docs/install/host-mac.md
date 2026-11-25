# Install the host on a Mac

[Deutsch](de/host-mac.md) · [Back to downloads](../../README.md#download)

**File:** `Remote-for-ADI-2-Host-macOS-1.3.0.zip` from the [download section](../../README.md#download).
**Requires:** Mac with the ADI-2 connected by USB; for Wi-Fi control, both devices must be on the same network.

Remote for ADI-2 Host includes its own interface for controlling the ADI-2 on the computer and provides Wi-Fi control from a smartphone, tablet or another computer. For a direct USB connection to the phone, the app is enough.

## 1. Install

1. Unzip the file and move **Remote for ADI-2 Host** to **Applications**.
2. Start it. The program is not signed by Apple, so macOS blocks the first start: open **System Settings → Privacy & Security** and choose **Open Anyway**.
3. The icon appears in the menu bar.

## Interface

A normal start opens the interface. The header offers **Desktop**, **Device only** and **Compact view**, plus separate analyzer and player windows. Details: [user guide](../USER_GUIDE.md#desktop-views-and-windows).

Closing the window keeps the host running in the background. Left-click the icon to open the interface; right-click for the menu. Starting the program again brings the running interface forward. Autostart through the icon menu starts only in the background. **Exit** in the menu quits the host.

Grant microphone access to **Remote for ADI-2 Host** when first starting the analyzer. It is needed for USB capture from the ADI-2. If denied, allow it under **System Settings → Privacy & Security → Microphone**, then choose **Try again** in the analyzer.

## 2. Pair a smartphone or tablet

1. In the host menu choose **Pair client…**.
2. In the app choose **Connect via host** and scan the QR code or enter the code.
3. Up to four smartphones or tablets can be connected at the same time; pair each one once.

Details: [user guide](../USER_GUIDE.md#control-through-a-computer-host).

## Control another computer

On the other computer, start Remote for ADI-2 Host (Mac/Windows) or Remote for ADI-2 (Linux), connect the ADI-2 by USB and enable **MIDI Control → ON**. Both computers must be on the same network.

Choose **Pair client…** in that computer’s icon menu. On the controlling computer, use **HOST** or **CLIENT** to open **Connect via host**, select the other computer and enter its code. **HOST** is green for this computer; **CLIENT** is blue when connected to another host. The active connection is marked. **This computer** switches back to the local ADI-2.

## Intel Mac

If the interface flickers or shows black or orange stripes on an Intel Mac (for example when pressing volume + or − quickly), use `Remote-for-ADI-2-Host-Intel-Mac-1.3.0.zip` instead. It is the same host with a different graphics renderer. Install it the same way and replace the existing app; settings and pairings are kept. It also runs on Apple silicon Macs, but the normal version is recommended there.

## Updates

The host reports new versions (can be switched off). Install the new version the same way, replacing the old app in Applications. Pairings and settings are kept.

## Using an iPhone

AltServer from AltStore can run next to the host on the same Mac; see [iPhone with AltStore](iphone-altstore.md).
