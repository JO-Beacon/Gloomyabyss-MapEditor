#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Let Dart drive the title bar colors so they always match the app
  // background (and stay opaque: no Mica / Acrylic).
  window_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "jodraft/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "destroy") {
          DestroyWindow(GetHandle());
          result->Success();
          return;
        }
        if (call.method_name() != "setCaption") {
          result->NotImplemented();
          return;
        }
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("bad_args", "expected a map");
          return;
        }
        auto read = [args](const char* key, int64_t fallback) -> int64_t {
          auto it = args->find(flutter::EncodableValue(std::string(key)));
          if (it == args->end()) {
            return fallback;
          }
          if (const int64_t* v = std::get_if<int64_t>(&it->second)) {
            return *v;
          }
          if (const int32_t* v = std::get_if<int32_t>(&it->second)) {
            return *v;
          }
          return fallback;
        };
        auto to_colorref = [](int64_t argb) -> COLORREF {
          const BYTE r = static_cast<BYTE>((argb >> 16) & 0xFF);
          const BYTE g = static_cast<BYTE>((argb >> 8) & 0xFF);
          const BYTE b = static_cast<BYTE>(argb & 0xFF);
          return RGB(r, g, b);
        };
        SetCaptionColors(to_colorref(read("caption", 0)),
                         to_colorref(read("text", 0xFFFFFF)),
                         to_colorref(read("border", 0)), read("dark", 0) != 0);
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_CLOSE: {
      // Let Dart decide whether to save and actually close.
      if (window_channel_) {
        window_channel_->InvokeMethod(
            "closeRequested", std::make_unique<flutter::EncodableValue>(),
            nullptr);
      }
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
