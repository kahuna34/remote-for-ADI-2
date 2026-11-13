#include "host_player.h"
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <algorithm>
#include <chrono>
#include <string>

namespace {
using namespace winrt;
using namespace Windows::Media::Control;
using namespace Windows::Storage::Streams;
using namespace Windows::Graphics::Imaging;
using flutter::EncodableValue;
using flutter::EncodableMap;

template <typename Operation>
auto Await(const Operation& operation) {
  if (operation.wait_for(std::chrono::seconds(2)) != Windows::Foundation::AsyncStatus::Completed) {
    operation.Cancel();
    throw hresult_error(E_ABORT);
  }
  return operation.GetResults();
}

std::string Cover(const IRandomAccessStreamReference& reference) {
  if (!reference) return {};
  try {
    auto input = Await(reference.OpenReadAsync());
    // Bound decoding work for malformed/very large images.
    if (input.Size() > 8000000) return {};
    auto decoder = Await(BitmapDecoder::CreateAsync(input));
    BitmapTransform transform;
    if (decoder.PixelWidth() == 0 || decoder.PixelHeight() == 0) return {};
    const double scale = 160.0 / (std::max)(decoder.PixelWidth(), decoder.PixelHeight());
    transform.ScaledWidth((std::max)(1u, static_cast<uint32_t>(decoder.PixelWidth() * scale)));
    transform.ScaledHeight((std::max)(1u, static_cast<uint32_t>(decoder.PixelHeight() * scale)));
    auto bitmap = Await(decoder.GetSoftwareBitmapAsync(
        BitmapPixelFormat::Bgra8, BitmapAlphaMode::Ignore, transform,
        ExifOrientationMode::RespectExifOrientation,
        ColorManagementMode::DoNotColorManage));
    InMemoryRandomAccessStream output;
    auto encoder = Await(BitmapEncoder::CreateAsync(BitmapEncoder::JpegEncoderId(), output));
    encoder.SetSoftwareBitmap(bitmap);
    Await(encoder.FlushAsync());
    if (output.Size() > 30000) return {};
    output.Seek(0);
    DataReader reader(output.GetInputStreamAt(0));
    const auto length = static_cast<uint32_t>(output.Size());
    Await(reader.LoadAsync(length));
    return to_string(Windows::Security::Cryptography::CryptographicBuffer::EncodeToBase64String(reader.ReadBuffer(length)));
  } catch (...) {
    return {};
  }
}

EncodableValue State(const GlobalSystemMediaTransportControlsSessionManager& manager) {
  EncodableMap state{{EncodableValue("playing"), EncodableValue(false)},
                     {EncodableValue("artwork"), EncodableValue()}};
  auto session = manager.GetCurrentSession();
  if (!session) return EncodableValue(state);
  auto properties = Await(session.TryGetMediaPropertiesAsync());
  // Limit UTF-16 before conversion; Dart also limits decoded text to 1024.
  auto text = [](const hstring& value) {
    return EncodableValue(to_string(std::wstring(value.c_str(), value.size()).substr(0, 512)));
  };
  state[EncodableValue("title")] = text(properties.Title());
  state[EncodableValue("artist")] = text(properties.Artist());
  state[EncodableValue("app")] = text(session.SourceAppUserModelId());
  state[EncodableValue("playing")] = EncodableValue(
      session.GetPlaybackInfo().PlaybackStatus() == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing);
  auto cover = Cover(properties.Thumbnail());
  if (!cover.empty()) state[EncodableValue("artwork")] = EncodableValue(cover);
  return EncodableValue(state);
}

void Command(const GlobalSystemMediaTransportControlsSessionManager& manager, const std::string& command) {
  auto session = manager.GetCurrentSession();
  if (!session) return;
  if (command == "play") Await(session.TryPlayAsync());
  else if (command == "pause") Await(session.TryPauseAsync());
  else if (command == "toggle") Await(session.TryTogglePlayPauseAsync());
  else if (command == "next") Await(session.TrySkipNextAsync());
  else if (command == "previous") Await(session.TrySkipPreviousAsync());
}
}  // namespace

HostPlayer::HostPlayer(flutter::BinaryMessenger* messenger, HWND window) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "adi2/host_player", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, std::unique_ptr<Result> reply) {
    auto result = std::shared_ptr<Result>(std::move(reply));
    const auto method = call.method_name();
    const auto* argument = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
    const std::string command = argument ? *argument : "";
    {
      std::lock_guard<std::mutex> lock(mutex_);
      // Dart serializes requests; also bound work if an unexpected caller floods us.
      if (jobs_.size() >= 8) { result->Error("busy", "Player busy"); return; }
      jobs_.push_back([this, result, method, command]() {
        EncodableValue value;
        try {
          auto manager = Await(GlobalSystemMediaTransportControlsSessionManager::RequestAsync());
          if (method == "state") value = State(manager);
          else if (method == "command") Command(manager, command);
        } catch (...) {
          value = EncodableValue(EncodableMap{
              {EncodableValue("playing"), EncodableValue(false)},
              {EncodableValue("artwork"), EncodableValue()}});
        }
        Complete(result, std::move(value));
      });
    }
    wake_.notify_one();
  });
  worker_ = std::thread([this] { Run(); });
}
HostPlayer::~HostPlayer() {
  channel_->SetMethodCallHandler(nullptr);
  { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; jobs_.clear(); }
  wake_.notify_one();
  if (worker_.joinable()) worker_.join();
  Drain();
}
void HostPlayer::Run() {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  for (;;) {
    std::function<void()> job;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      wake_.wait(lock, [this] { return stopping_ || !jobs_.empty(); });
      if (stopping_) break;
      job = std::move(jobs_.front()); jobs_.pop_front();
    }
    job();
  }
  winrt::uninit_apartment();
}
void HostPlayer::Complete(std::shared_ptr<Result> result, EncodableValue value) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    completions_.push_back([result, value = std::move(value)] { result->Success(value); });
  }
  PostMessage(window_, kMessage, 0, 0);
}
void HostPlayer::Drain() {
  std::deque<std::function<void()>> completed;
  { std::lock_guard<std::mutex> lock(mutex_); completed.swap(completions_); }
  for (auto& completion : completed) completion();
}
