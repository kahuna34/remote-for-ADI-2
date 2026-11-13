#ifndef RUNNER_HOST_PLAYER_H_
#define RUNNER_HOST_PLAYER_H_
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

// All WinRT waits run on a dedicated MTA, never on Flutter's window thread.
class HostPlayer {
 public:
  static constexpr UINT kMessage = WM_APP + 62;
  HostPlayer(flutter::BinaryMessenger* messenger, HWND window);
  ~HostPlayer();
  void Drain();
 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;
  void Run();
  void Complete(std::shared_ptr<Result> result, flutter::EncodableValue value);
  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::mutex mutex_;
  std::condition_variable wake_;
  bool stopping_ = false;
  std::deque<std::function<void()>> jobs_, completions_;
  std::thread worker_;
};
#endif
