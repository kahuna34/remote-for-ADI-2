#ifndef RUNNER_ANALYZER_CAPTURE_H_
#define RUNNER_ANALYZER_CAPTURE_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <atomic>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Native capture only. Flutter channels and event sinks stay on the UI thread.
class AnalyzerCapture {
 public:
  static constexpr UINT kMessage = WM_APP + 71;
  AnalyzerCapture(flutter::BinaryMessenger* messenger, HWND window);
  ~AnalyzerCapture();
  void Drain();
 private:
  struct Packet {
    std::vector<double> pcm;
    int rate = 0;
    std::string device, computer, error;
  };
  void Start();
  void Stop();
  void Run();
  void Queue(Packet packet);
  HWND window_;
  HANDLE stop_;
  std::thread worker_;
  std::atomic<bool> stopping_{true};
  std::mutex mutex_;
  std::deque<Packet> packets_;
  size_t queued_samples_ = 0;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
};
#endif
