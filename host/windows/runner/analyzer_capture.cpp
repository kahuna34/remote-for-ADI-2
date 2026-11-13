#include "analyzer_capture.h"
#include "analyzer_pcm.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <initguid.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cwctype>
#include <stdexcept>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;
void Check(HRESULT hr) { if (FAILED(hr)) throw hr; }
std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, 0, text.data(),
      static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string result(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
      result.data(), count, nullptr, nullptr);
  return result;
}
struct ComScope {
  ComScope() { Check(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)); }
  ~ComScope() { CoUninitialize(); }
};
struct AudioStop {
  IAudioClient* audio;
  ~AudioStop() { audio->Stop(); }
};
struct Handle {
  HANDLE value = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  ~Handle() { if (value) CloseHandle(value); }
};
std::string ErrorCode(HRESULT hr) {
  return hr == E_ACCESSDENIED || hr == HRESULT_FROM_WIN32(ERROR_ACCESS_DISABLED_BY_POLICY)
      ? "analyzer_permission" : "analyzer_no_input";
}
}  // namespace

AnalyzerCapture::AnalyzerCapture(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window), stop_(CreateEvent(nullptr, TRUE, FALSE, nullptr)) {
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  method_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "adi2/analyzer", codec);
  events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "adi2/analyzer/events", codec);
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sink_ = std::move(sink); return nullptr;
      },
      [this](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        Stop(); sink_.reset(); return nullptr;
      }));
  method_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& name = call.method_name();
    if (name == "permission" || name == "requestPermission") {
      // Windows grants/denies access when IAudioClient activates/initializes.
      result->Success(EncodableValue(true));
    } else if (name == "start") {
      try { Start(); result->Success(); }
      catch (...) { result->Error("analyzer_no_input", "Capture unavailable"); }
    } else if (name == "stop") {
      Stop(); result->Success();
    } else if (name == "setBandResolution") {
      result->Success();
    } else { result->NotImplemented(); }
  });
}

AnalyzerCapture::~AnalyzerCapture() {
  Stop();
  method_->SetMethodCallHandler(nullptr);
  events_->SetStreamHandler(nullptr);
  if (stop_) CloseHandle(stop_);
}

void AnalyzerCapture::Start() {
  Stop();
  if (!stop_) throw std::runtime_error("Capture stop event unavailable");
  ResetEvent(stop_);
  stopping_ = false;
  worker_ = std::thread([this] { Run(); });
}

void AnalyzerCapture::Stop() {
  stopping_ = true;
  if (stop_) SetEvent(stop_);
  if (worker_.joinable()) worker_.join();
  std::lock_guard<std::mutex> lock(mutex_);
  packets_.clear(); queued_samples_ = 0;
}

void AnalyzerCapture::Queue(Packet packet) {
  if (stopping_) return;
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopping_) return;
  // Bound the bridge to 250 ms. A stall fails instead of leaking memory or
  // silently joining discontinuous audio. There is only one posted UI wakeup.
  if (packet.rate && queued_samples_ + packet.pcm.size() >
      static_cast<size_t>(packet.rate / 2)) {
    packet = Packet{}; packet.error = "analyzer_no_input";
    packets_.clear(); queued_samples_ = 0;
    stopping_ = true; SetEvent(stop_);
  }
  const bool wake = packets_.empty();
  queued_samples_ += packet.pcm.size();
  packets_.push_back(std::move(packet));
  if (wake) PostMessage(window_, kMessage, 0, 0);
}

void AnalyzerCapture::Drain() {
  std::deque<Packet> packets;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    packets.swap(packets_); queued_samples_ = 0;
  }
  for (auto& p : packets) {
    if (!sink_) return;
    if (!p.error.empty()) {
      sink_->Success(EncodableValue(EncodableMap{
        {EncodableValue("status"), EncodableValue(p.error)}}));
      return;
    }
    sink_->Success(EncodableValue(EncodableMap{
      {EncodableValue("pcm"), EncodableValue(std::move(p.pcm))},
      {EncodableValue("sampleRate"), EncodableValue(p.rate)},
      {EncodableValue("device"), EncodableValue(p.device)},
      {EncodableValue("routeVerified"), EncodableValue(true)},
      {EncodableValue("calibrationIdentity"), EncodableValue(EncodableMap{
        {EncodableValue("hostManufacturer"), EncodableValue("Windows")},
        {EncodableValue("hostModel"), EncodableValue(p.computer)},
        {EncodableValue("usbName"), EncodableValue(p.device)}})}}));
  }
}

void AnalyzerCapture::Run() {
  try {
    ComScope com;
    ComPtr<IMMDeviceEnumerator> enumerator;
    Check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        IID_PPV_ARGS(&enumerator)));
    ComPtr<IMMDeviceCollection> collection;
    Check(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &collection));
    UINT count = 0; Check(collection->GetCount(&count));
    ComPtr<IMMDevice> device;
    std::string name;
    for (UINT i = 0; i < count; i++) {
      ComPtr<IMMDevice> candidate; Check(collection->Item(i, &candidate));
      ComPtr<IPropertyStore> properties; Check(candidate->OpenPropertyStore(STGM_READ, &properties));
      PROPVARIANT value; PropVariantInit(&value);
      const HRESULT hr = properties->GetValue(PKEY_Device_FriendlyName, &value);
      std::wstring friendly = SUCCEEDED(hr) && value.vt == VT_LPWSTR && value.pwszVal
          ? value.pwszVal : L"";
      PropVariantClear(&value);
      auto upper = friendly;
      std::transform(upper.begin(), upper.end(), upper.begin(),
          [](wchar_t ch) { return static_cast<wchar_t>(std::towupper(ch)); });
      if (upper.find(L"ADI-2") == std::wstring::npos) continue;
      // Refuse an ambiguous route rather than recording another attached unit.
      if (device) throw E_FAIL;
      device = candidate; name = Utf8(friendly);
    }
    if (!device) throw HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    wchar_t computer[MAX_COMPUTERNAME_LENGTH + 1] = {};
    DWORD length = MAX_COMPUTERNAME_LENGTH + 1;
    GetComputerNameW(computer, &length);
    const std::string computer_name = Utf8(computer);
    ComPtr<IAudioClient> audio;
    Check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
        reinterpret_cast<void**>(audio.GetAddressOf())));
    WAVEFORMATEX* raw = nullptr; Check(audio->GetMixFormat(&raw));
    const std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)> format(raw, CoTaskMemFree);
    bool floating = raw->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    bool pcm = raw->wFormatTag == WAVE_FORMAT_PCM;
    if (raw->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
        raw->cbSize >= static_cast<WORD>(sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX))) {
      const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(raw);
      floating = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
      pcm = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
    }
    const WORD bits = raw->wBitsPerSample;
    if (raw->nChannels < 2 || raw->nSamplesPerSec < 40000 || raw->nSamplesPerSec > 1536000 ||
        !((floating && bits == 32) || (pcm && (bits == 16 || bits == 24 || bits == 32))) ||
        raw->nBlockAlign != raw->nChannels * (bits / 8)) throw E_FAIL;
    Handle ready;
    if (!ready.value) throw E_FAIL;
    Check(audio->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        0, 0, raw, nullptr));
    Check(audio->SetEventHandle(ready.value));
    ComPtr<IAudioCaptureClient> capture;
    Check(audio->GetService(IID_PPV_ARGS(&capture)));
    Check(audio->Start());
    AudioStop stop_audio{audio.Get()};
    const HANDLE waits[] = {stop_, ready.value};
    HRESULT failure = S_OK;
    bool have_packet = false;
    while (!stopping_) {
      const DWORD wait = WaitForMultipleObjects(2, waits, FALSE, 2000);
      if (wait == WAIT_OBJECT_0) break;
      if (wait != WAIT_OBJECT_0 + 1) { failure = E_FAIL; break; }
      UINT32 available = 0;
      failure = capture->GetNextPacketSize(&available);
      if (FAILED(failure)) break;
      while (available && !stopping_) {
        BYTE* data = nullptr; UINT32 frames = 0; DWORD flags = 0;
        failure = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(failure)) break;
        const bool discontinuity = have_packet && (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY);
        Packet packet; packet.rate = static_cast<int>(raw->nSamplesPerSec);
        packet.device = name; packet.computer = computer_name;
        try {
          packet.pcm.resize(static_cast<size_t>(frames) * 2);
          if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && data) {
            for (UINT32 frame = 0; frame < frames; frame++) {
              const BYTE* p = data + static_cast<size_t>(frame) * raw->nBlockAlign;
              packet.pcm[frame * 2] = adi2::AnalyzerPcmSample(p, bits, floating);
              packet.pcm[frame * 2 + 1] = adi2::AnalyzerPcmSample(p + bits / 8, bits, floating);
            }
          }
        } catch (...) { capture->ReleaseBuffer(frames); throw; }
        failure = capture->ReleaseBuffer(frames);
        if (FAILED(failure) || discontinuity) { failure = E_FAIL; break; }
        have_packet = true;
        Queue(std::move(packet));
        failure = capture->GetNextPacketSize(&available);
        if (FAILED(failure)) break;
      }
      if (FAILED(failure)) break;
    }
    Check(failure);
  } catch (HRESULT hr) {
    Packet error; error.error = ErrorCode(hr); Queue(std::move(error));
  } catch (...) {
    Packet error; error.error = "analyzer_no_input"; Queue(std::move(error));
  }
}
