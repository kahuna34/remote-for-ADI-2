# Computer control: host and Linux

Version **1.3.0 (10)** · [Deutsch](HOST_PLAN.de.md) · [User guide](USER_GUIDE.md#control-through-a-computer-host)

**Remote for ADI-2 Host** on Mac and Windows includes device controls on the computer and Wi-Fi control from smartphones, tablets and other computers. **Remote for ADI-2** on Linux combines the same interface and host in one AppImage.

## Interface and startup

A normal start opens the interface. Desktop, Device only and Compact views are available, with separate analyzer and player windows. Closing the main window keeps the host running in the background. Starting it again brings the running interface forward. On Mac and Windows, left-click the icon to open the interface and right-click for the menu; on Linux use the tray menu. Autostart starts only in the background. Exit in the icon menu quits the program.

## Pairing and host-to-host control

Connect the ADI-2 by USB and enable MIDI Control. Choose **Pair client…** in its computer’s icon menu, then **Connect via host** on the controlling device. Scan the QR code or enter the code. Pair every device separately; up to four remote clients can connect at the same time. Pairings can be revoked in the icon menu.

A computer can also select another computer under **Connect via host** and enter its pairing code. **HOST** in green means this computer; **CLIENT** in blue means another host. Host selection marks the active connection; **This computer** returns to the local ADI-2. The selected host also supplies analyzer and player data.

## Analyzer and player

The host captures ADI-2 USB channels 1/2 only while an analyzer is visible and does not save audio. Use loopback **post FX** to compare with the device display; **post −6 dB** reads 6 dB lower. Local desktop interfaces offer 30/60 fps, default 30.

On Mac, allow microphone permission for USB capture. Windows requires desktop-app microphone access. Linux capture uses PipeWire/PulseAudio, is bit-perfect and needs no calibration. The test-signal generator is available only on Linux with a local ADI-2.

The Mac player supports running Music and Spotify instances and requires Automation permission. Windows uses active media sessions; Linux uses MPRIS. Metadata, artwork and controls depend on the player.

## Volume protection

The device supplies the current settings. Clients share the maximum volume rise rate per output. A client’s volume increase stops when it disconnects or stops signalling the host; no increase is caught up later. Lowering volume, muting and Dim remain immediate. Loading device setups and factory settings through the host is blocked because they may recall unknown levels. App limits require an active connection and are not permanent hardware protection.

## Installation and verification

- [Mac](install/host-mac.md), [Windows](install/host-windows.md), [Linux](install/linux.md).
- Mac interface and analyzer checked with ADI-2 Pro; Linux Mint interface, analyzer, player, autostart and smartphone pairing checked with ADI-2 Pro.
- Windows host built and checked with ADI-2 DAC. Manual checks of some tray, login, auxiliary-window and host-to-host workflows remain open.
- Host-to-host control checked between Linux and Mac. Other platform combinations still need hardware verification.
