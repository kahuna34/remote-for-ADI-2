#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <memory>
#include <string>

#include "flutter_window.h"
#include "utils.h"

// Schreibt eine Zeile in %LOCALAPPDATA%\Remote for ADI-2 Host\host.log,
// dieselbe Datei wie das Protokoll des Hosts.
static void AppendLog(const char* message) {
  wchar_t base[MAX_PATH];
  const DWORD length = ::GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return;
  }
  std::wstring dir = std::wstring(base) + L"\\Remote for ADI-2 Host";
  ::CreateDirectoryW(dir.c_str(), nullptr);
  FILE* file = nullptr;
  if (_wfopen_s(&file, (dir + L"\\host.log").c_str(), L"a") != 0 || !file) {
    return;
  }
  SYSTEMTIME time;
  ::GetLocalTime(&time);
  fprintf(file, "%04d-%02d-%02dT%02d:%02d:%02d [%lu] Runner: %s\n", time.wYear,
          time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond,
          ::GetCurrentProcessId(), message);
  fclose(file);
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  // Dart owns the per-user instance lock and authenticated activation IPC.
  // Auxiliary processes must reach Dart before any instance check.
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // Skia statt Impeller: Beim Ziehen der Fenstergröße wartete das Fenster je
  // Schritt im Median ~13 ms (Impeller) statt ~8,5 ms (Skia, wie eine leere
  // Flutter-App), gemessen 2026-11-23. Keine Shader in der App, Leerlauf-CPU
  // gleich.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  const bool auxiliary_window = std::any_of(
      command_line_arguments.begin(), command_line_arguments.end(),
      [](const std::string& arg) { return arg.rfind("--window=", 0) == 0; });
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, auxiliary_window);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Remote for ADI-2", origin, size)) {
    AppendLog("Fenster konnte nicht erstellt werden");
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
