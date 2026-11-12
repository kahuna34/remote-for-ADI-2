import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

// win32 does not yet expose SetupDiGetDevicePropertyW. Use its native structs
// and bind this Unicode-only API directly; loading stays lazy on macOS.
final _deviceProperty = DynamicLibrary.open('setupapi.dll')
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<SP_DEVINFO_DATA>,
        Pointer<DEVPROPKEY>,
        Pointer<Uint32>,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint32>,
        Uint32,
      ),
      int Function(
        int,
        Pointer<SP_DEVINFO_DATA>,
        Pointer<DEVPROPKEY>,
        Pointer<Uint32>,
        Pointer<Uint8>,
        int,
        Pointer<Uint32>,
        int,
      )
    >('SetupDiGetDevicePropertyW');

class WindowsPnp {
  /// A new PRESENT-only MEDIA snapshot on every call, independent of WinMM.
  /// Never opens a MIDI port, spawns a process or requests elevated access.
  static List<String> productNames() {
    if (!Platform.isWindows) return const [];
    return using((arena) {
      final media = GUID_DEVCLASS_MEDIA.toNative(allocator: arena);
      final info = arena<SP_DEVINFO_DATA>();
      info.ref.cbSize = sizeOf<SP_DEVINFO_DATA>();
      final busKey = arena<DEVPROPKEY>();
      // DEVPKEY_Device_BusReportedDeviceDesc, devpkey.h.
      busKey.ref.fmtid.setGUID('540b947e-8b40-45bc-a8a2-6a0b894cbda2');
      busKey.ref.pid = 4;
      final type = arena<Uint32>();
      final bytes = arena<Uint32>();
      const capacity = 4096;
      final buffer = arena<Uint8>(capacity);
      final snapshot = SetupDiGetClassDevs(media, null, null, DIGCF_PRESENT);
      final handle = snapshot.value;
      if (!handle.isValid) {
        throw StateError('SetupDiGetClassDevs: ${snapshot.error}');
      }
      String? readString(
        bool bus, [
        SETUP_DI_REGISTRY_PROPERTY property = SPDRP_FRIENDLYNAME,
      ]) {
        type.value = 0;
        bytes.value = 0;
        final ok = bus
            ? _deviceProperty(
                    handle,
                    info,
                    busKey,
                    type,
                    buffer,
                    capacity,
                    bytes,
                    0,
                  ) !=
                  0
            : SetupDiGetDeviceRegistryProperty(
                handle,
                info,
                property,
                type,
                buffer,
                capacity,
                bytes,
              ).value;
        // DEVPROP_TYPE_STRING / REG_SZ; count includes the UTF-16 terminator.
        if (!ok || type.value != (bus ? 0x12 : REG_SZ)) return null;
        final length = bytes.value;
        if (length < 2 || length > capacity || length.isOdd) return null;
        final chars = buffer.cast<Uint16>().asTypedList(length ~/ 2);
        final end = chars.indexOf(0);
        return String.fromCharCodes(end < 0 ? chars : chars.sublist(0, end));
      }

      try {
        final names = <String>[];
        for (var index = 0; ; index++) {
          final next = SetupDiEnumDeviceInfo(handle, index, info);
          if (!next.value) {
            if (next.error == ERROR_NO_MORE_ITEMS) break;
            throw StateError('SetupDiEnumDeviceInfo: ${next.error}');
          }
          // Viele Treiber setzen keinen FriendlyName; Get-PnpDevice zeigt
          // dann die Gerätebeschreibung. Beides prüfen, dazu die Busangabe.
          final friendly =
              readString(false) ?? readString(false, SPDRP_DEVICEDESC);
          final bus = readString(true);
          if (!isAdi2(friendly) && !isAdi2(bus)) continue;
          names.add(deviceName(friendly ?? bus!, bus));
        }
        return names;
      } finally {
        SetupDiDestroyDeviceInfoList(handle);
      }
    });
  }

  static bool isAdi2(String? name) =>
      name != null &&
      RegExp(r'^(RME\s+)?ADI-2', caseSensitive: false).hasMatch(name.trim());

  /// The bus description supplies the real serial, never the USB instance ID.
  /// A temporarily missing description must not hide a present device.
  static String deviceName(String friendly, String? bus) =>
      (isAdi2(bus) ? bus! : friendly).trim().replaceFirst(
        RegExp(r'^RME\s+', caseSensitive: false),
        '',
      );
}
