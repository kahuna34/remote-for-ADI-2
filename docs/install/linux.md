# Install Remote for ADI-2 on Linux

[Deutsch](de/linux.md) · [Back to downloads](../../README.md#download)

**File:** `Remote-for-ADI-2-Linux-1.3.0.AppImage` from the [download section](../../README.md#download).
**Requires:** Linux PC (x86_64), e.g. Linux Mint 22 / Ubuntu 24.04, and an ADI-2 connected by USB. For Wi-Fi control, both devices must be on the same network.

Remote for ADI-2 combines the desktop interface and host in one program.

## 1. Download and start

1. Download the AppImage and keep it in a permanent folder, including when using autostart.
2. In the file’s **Properties → Permissions**, allow executing it as a program. Alternatively, open a terminal in the download folder and run:

   ```sh
   chmod +x Remote-for-ADI-2-Linux-1.3.0.AppImage
   ```

3. Double-click the AppImage. The interface opens and an icon appears in the tray.

On Mint/Ubuntu, install the following runtime packages if missing:

```sh
sudo apt update
sudo apt install pulseaudio-utils libayatana-appindicator3-1 avahi-daemon
```

- **pulseaudio-utils** provides `pactl`, `parec` and `pacat` for analyzer capture and test signals. A working PipeWire setup with PulseAudio compatibility, or PulseAudio, is required. `pw-record` from **pipewire-bin** is an alternative capture tool; `pactl` is still required.
- **libayatana-appindicator3-1** provides AppIndicator support for the tray icon. The desktop must support StatusNotifier/AppIndicator icons.
- **avahi-daemon** enables host discovery on the local network. Mint/Ubuntu normally includes it.
- If the AppImage reports missing FUSE support, install **libfuse2t64** on Mint 22 / Ubuntu 24.04 (`sudo apt install libfuse2t64`). On older Ubuntu versions the package is named **libfuse2**.

GTK 3, ALSA and a desktop D-Bus session must be available; Mint/Ubuntu normally provides them. File dialogs use **xdg-desktop-portal** and **xdg-desktop-portal-gtk**, normally included too.

## 2. Connect the ADI-2

1. Connect the ADI-2 with a data-capable USB cable.
2. Enable **MIDI Control → ON** on the ADI-2:
   - DAC: **SETUP → Options → Remap Keys / Diag → MIDI Control**
   - ADI-2 Pro / ADI-2/4 Pro: **SETUP → Options → Device Mode / DSD → MIDI Control**
3. Check the detected model in the interface. For analyzer comparison with the device display, select loopback **post FX** on USB **1/2**. Linux capture needs no level calibration.

## 3. Interface and autostart

The header offers Desktop, Device only and Compact views, plus separate analyzer and player windows. Player control requires an **MPRIS** player, such as VLC. Test signals are under **App settings → Test signals** and work only with the local ADI-2.

Closing the window keeps the program running in the tray. Right-click the icon and choose **Open interface** to return. Starting the AppImage again also opens the running interface. Enable **Start at login** in the tray menu for background autostart without a window. **Exit** quits the program.

## 4. Pair a smartphone or control another computer

Choose **Pair client…** in the tray menu. On the smartphone, open **Connect via host** and scan the QR code or enter the code. Pair each device separately; up to four smartphones or tablets can connect at the same time.

To control the ADI-2 attached to another computer, open **Pair client…** on that computer. In the Linux interface, click **HOST** or **CLIENT**, open **Connect via host**, select that computer and enter its code. **HOST** is green for this computer, **CLIENT** blue for another host; the active connection is marked. **This computer** returns to the local host.

Details: [user guide](../USER_GUIDE.md#linux).

## Updates

The program reports new versions (can be switched off). Quit it through the tray menu and replace the AppImage with the new version. Settings and pairings are kept. Start the new file once so an enabled autostart entry uses its current location.
