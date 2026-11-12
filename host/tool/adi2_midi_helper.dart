// Remote for ADI-2 Host: standalone WinMM transport, without Flutter.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'package:adi2_host/midi_helper_protocol.dart';

const _stopWindow = WM_APP + 1;

/// A message-only window has no visible surface. GetMessage blocks only this
/// isolate; the main isolate can service stdin and WinMM without polling.
void _windowPump(SendPort parent) {
  try {
    using((arena) {
      final window = CreateWindowEx(
        const WINDOW_EX_STYLE(0),
        PCWSTR('STATIC'.toNativeUtf16(allocator: arena)),
        null,
        const WINDOW_STYLE(0),
        0,
        0,
        0,
        0,
        HWND_MESSAGE,
        null,
        null,
        null,
      ).value;
      if (window == nullptr) throw StateError('CreateWindowEx');
      final msg = arena<MSG>();
      // Preserve GetMessage's three return states (the win32 bool wrapper
      // cannot distinguish -1 from a normal message).
      final getMessage = DynamicLibrary.open('user32.dll')
          .lookupFunction<
            Int32 Function(Pointer<MSG>, Pointer, Uint32, Uint32),
            int Function(Pointer<MSG>, Pointer, int, int)
          >('GetMessageW');
      parent.send(['window', window.address]);
      try {
        while (true) {
          final result = getMessage(msg, nullptr, 0, 0);
          if (result == -1) throw StateError('GetMessage: ${GetLastError()}');
          if (result == 0 || msg.ref.message == _stopWindow) break;
          final message = msg.ref.message;
          if (message >= MM_MIM_OPEN && message <= MM_MOM_DONE ||
              message == MM_MIM_MOREDATA) {
            // WinMM owns the buffer until it posts LONGDATA/DONE. It stays
            // allocated until the main isolate handles this notification.
            parent.send(['midi', message, msg.ref.lParam.toInt()]);
          } else {
            TranslateMessage(msg);
            DispatchMessage(msg);
          }
        }
      } finally {
        DestroyWindow(window);
      }
    });
  } catch (error) {
    parent.send(['error', error.toString()]);
  } finally {
    parent.send(['done']);
  }
}

class _MidiError implements Exception {
  _MidiError(this.result, this.operation);
  final int result;
  final String operation;
  String get code => switch (result) {
    MMSYSERR_ALLOCATED || MMSYSERR_HANDLEBUSY => 'busy',
    MMSYSERR_BADDEVICEID ||
    MMSYSERR_NODRIVER ||
    MMSYSERR_INVALHANDLE ||
    MIDIERR_NODEVICE => 'missing',
    _ => 'io',
  };
  @override
  String toString() => '$operation ($result)';
}

void _check(int result, String operation) {
  if (result != MMSYSERR_NOERROR) throw _MidiError(result, operation);
}

MidiHelperPorts _ports() => using((arena) {
  final input = arena<MIDIINCAPS>();
  final output = arena<MIDIOUTCAPS>();
  return MidiHelperPorts(
    [
      for (var id = 0; id < midiInGetNumDevs(); id++)
        if (midiInGetDevCaps(id, input, sizeOf<MIDIINCAPS>()) == 0)
          MidiHelperPort(id, input.ref.szPname),
    ],
    [
      for (var id = 0; id < midiOutGetNumDevs(); id++)
        if (midiOutGetDevCaps(id, output, sizeOf<MIDIOUTCAPS>()) == 0)
          MidiHelperPort(id, output.ref.szPname),
    ],
  );
});

class _WinMidi {
  final _input = calloc<Pointer>();
  final _output = calloc<Pointer>();
  final _headers = <Pointer<MIDIHDR>>[];
  final _sending = <int, Pointer<MIDIHDR>>{};
  final _assembler = SysexAssembler();
  final _messages = ReceivePort();
  final _windowReady = Completer<int>();
  final _windowDone = Completer<void>();
  final stopped = Completer<void>();
  late final StreamSubscription<dynamic> _events;
  Isolate? _pump;
  HWND? _window;
  bool _closing = false, _lost = false;
  HMIDIIN get input => HMIDIIN(_input.value);
  HMIDIOUT get output => HMIDIOUT(_output.value);

  Future<void> open(String name) async {
    final ports = _ports();
    final ins = ports.inputs.where((p) => p.name == name);
    final outs = ports.outputs.where((p) => p.name == name);
    if (ins.isEmpty || outs.isEmpty) {
      throw _MidiError(MMSYSERR_BADDEVICEID, 'Port missing');
    }
    _events = _messages.listen((event) {
      final row = event as List;
      switch (row[0]) {
        case 'window':
          _windowReady.complete(row[1] as int);
        case 'midi':
          if (!_closing) {
            try {
              _message(row[1] as int, row[2] as int);
            } catch (error) {
              lost(error.toString());
            }
          }
        case 'error':
          if (!_windowReady.isCompleted) {
            _windowReady.completeError(StateError(row[1] as String));
          } else {
            lost(row[1] as String);
          }
        case 'done':
          if (!_windowDone.isCompleted) _windowDone.complete();
          if (!_closing) lost('MIDI window closed');
      }
    });
    _pump = await Isolate.spawn(_windowPump, _messages.sendPort);
    _window = HWND(Pointer.fromAddress(await _windowReady.future));
    _check(
      midiInOpen(_input, ins.first.id, _window!.address, 0, CALLBACK_WINDOW),
      'midiInOpen',
    );
    _check(
      midiOutOpen(_output, outs.first.id, _window!.address, 0, CALLBACK_WINDOW),
      'midiOutOpen',
    );
    // Several queued buffers avoid gaps while a completed buffer crosses the
    // isolate boundary. Each can hold every supported ADI-2 SysEx message.
    for (var i = 0; i < 8; i++) {
      final header = _buffer(4096);
      _headers.add(header);
      _check(
        midiInPrepareHeader(input, header, sizeOf<MIDIHDR>()),
        'midiInPrepareHeader',
      );
      _check(
        midiInAddBuffer(input, header, sizeOf<MIDIHDR>()),
        'midiInAddBuffer',
      );
    }
    _check(midiInStart(input), 'midiInStart');
  }

  Pointer<MIDIHDR> _buffer(int length) {
    final header = calloc<MIDIHDR>();
    header.ref.lpData = PSTR(calloc<Uint8>(length).cast());
    header.ref.dwBufferLength = length;
    return header;
  }

  void _free(Pointer<MIDIHDR> header) {
    calloc.free(header.ref.lpData);
    calloc.free(header);
  }

  void _message(int message, int parameter) {
    switch (message) {
      case MM_MIM_DATA:
      case MM_MIM_MOREDATA:
        emit(encodeMidiLine(unpackShortMidi(parameter)));
      case MM_MIM_LONGDATA:
        final header = Pointer<MIDIHDR>.fromAddress(parameter);
        if (!_headers.contains(header)) {
          throw StateError('Unknown input buffer');
        }
        final bytes = header.ref.lpData.cast<Uint8>().asTypedList(
          header.ref.dwBytesRecorded,
        );
        for (final packet in _assembler.add(bytes)) {
          emit(encodeMidiLine(packet));
        }
        header.ref.dwBytesRecorded = 0;
        _check(
          midiInAddBuffer(input, header, sizeOf<MIDIHDR>()),
          'midiInAddBuffer',
        );
      case MM_MOM_DONE:
        final header = _sending.remove(parameter);
        if (header != null) {
          final result = midiOutUnprepareHeader(
            output,
            header,
            sizeOf<MIDIHDR>(),
          );
          if (result != 0) {
            _sending[parameter] = header;
            _check(result, 'midiOutUnprepareHeader');
          }
          _free(header);
        }
      case MM_MIM_CLOSE:
      case MM_MOM_CLOSE:
      case MM_MIM_ERROR:
      case MM_MIM_LONGERROR:
        lost('WinMM message $message');
    }
  }

  void send(List<int> bytes) {
    if (_closing || _lost) return;
    if (bytes.first != 0xf0) {
      final short = unpackShortMidi(bytes.first);
      if (short.length != bytes.length) {
        throw const FormatException('Short MIDI length');
      }
      var packed = 0;
      for (var i = 0; i < bytes.length; i++) {
        packed |= bytes[i] << (8 * i);
      }
      _check(midiOutShortMsg(output, packed), 'midiOutShortMsg');
      return;
    }
    if (bytes.last != 0xf7) throw const FormatException('Incomplete SysEx');
    final header = _buffer(bytes.length);
    header.ref.lpData.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    _sending[header.address] = header;
    _check(
      midiOutPrepareHeader(output, header, sizeOf<MIDIHDR>()),
      'midiOutPrepareHeader',
    );
    _check(midiOutLongMsg(output, header, sizeOf<MIDIHDR>()), 'midiOutLongMsg');
  }

  void emit(String line) {
    if (_closing) return;
    stdout.writeln(line);
    unawaited(
      stdout.flush().catchError((Object _) {
        if (!stopped.isCompleted) stopped.complete();
      }),
    );
  }

  void lost(String reason) {
    if (_lost || _closing) return;
    _lost = true;
    emit('lost ${reason.replaceAll(RegExp(r'[\r\n]'), ' ')}');
    if (!stopped.isCompleted) stopped.complete();
  }

  Future<void> close() async {
    _closing = true;
    // Reset returns pending buffers. Free only successfully unprepared memory;
    // a faulty driver retaining a buffer must not receive a dangling pointer.
    if (_input.value != nullptr) {
      midiInStop(input);
      midiInReset(input);
      for (final header in _headers) {
        if (midiInUnprepareHeader(input, header, sizeOf<MIDIHDR>()) == 0) {
          _free(header);
        }
      }
      midiInClose(input);
    } else {
      for (final header in _headers) {
        _free(header);
      }
    }
    if (_output.value != nullptr) {
      midiOutReset(output);
      for (final header in _sending.values) {
        if (midiOutUnprepareHeader(output, header, sizeOf<MIDIHDR>()) == 0) {
          _free(header);
        }
      }
      midiOutClose(output);
    }
    calloc.free(_input);
    calloc.free(_output);
    final window = _window;
    if (window != null) {
      PostMessage(window, _stopWindow, const WPARAM(0), const LPARAM(0));
      try {
        await _windowDone.future.timeout(const Duration(seconds: 1));
      } catch (_) {
        _pump?.kill(priority: Isolate.immediate);
      }
    }
    _messages.close();
    if (_pump != null) await _events.cancel();
  }
}

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('Remote for ADI-2 Host MIDI helper requires Windows.');
    exitCode = 1;
    return;
  }
  if (args.length == 1 && args.single == 'list') {
    try {
      stdout.writeln(_ports().encode());
      await stdout.flush();
    } catch (error) {
      stderr.writeln(error);
      exitCode = 1;
    }
    return;
  }
  if (args.length != 2 ||
      args.first != 'open' ||
      args[1].contains(RegExp(r'[\r\n]'))) {
    stdout.writeln('error protocol Expected list or open <portname>');
    await stdout.flush();
    exitCode = 1;
    return;
  }
  final midi = _WinMidi();
  StreamSubscription<String>? commands;
  var opened = false;
  try {
    await midi.open(args[1]);
    // No await between Start and OK: this must precede all MIDI output lines.
    stdout.writeln('ok ${args[1]}');
    opened = true;
    await stdout.flush();
    commands = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              midi.send(decodeMidiLine(line));
            } catch (error) {
              midi.lost(error.toString());
            }
          },
          onDone: () {
            if (!midi.stopped.isCompleted) midi.stopped.complete();
          },
          onError: (Object error) => midi.lost(error.toString()),
        );
    // Stdin is a parent-owned pipe; EOF also occurs if the parent disappears.
    await midi.stopped.future;
  } catch (error) {
    if (opened) {
      midi.lost(error.toString());
    } else {
      final code = error is _MidiError ? error.code : 'io';
      stdout.writeln(
        'error $code ${error.toString().replaceAll(RegExp(r'[\r\n]'), ' ')}',
      );
    }
    exitCode = 1;
  } finally {
    await midi.close();
    await commands?.cancel();
    try {
      await stdout.flush();
    } catch (_) {}
  }
}
