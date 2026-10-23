#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayShow = 1;
constexpr UINT kTrayQuit = 2;

std::wstring Widen(const std::string& text) {
  if (text.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                   static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), length);
  return wide;
}

std::string StringArgument(const flutter::EncodableMap& map, const char* key) {
  auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) return std::string();
  const auto* text = std::get_if<std::string>(&found->second);
  return text ? *text : std::string();
}

}  // namespace

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

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dev.conest.conest/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "setCloseToTray") {
          bool enabled = false;
          std::wstring tooltip = L"Conest";
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto found = map->find(flutter::EncodableValue("enabled"));
            if (found != map->end()) {
              if (const auto* value = std::get_if<bool>(&found->second)) {
                enabled = *value;
              }
            }
            const std::string show = StringArgument(*map, "show");
            const std::string quit = StringArgument(*map, "quit");
            const std::string tip = StringArgument(*map, "tooltip");
            if (!show.empty()) tray_show_label_ = Widen(show);
            if (!quit.empty()) tray_quit_label_ = Widen(quit);
            if (!tip.empty()) tooltip = Widen(tip);
          }
          SetTray(enabled, tooltip);
          result->Success(flutter::EncodableValue(tray_added_));
        } else if (method == "show") {
          ShowFromTray();
          result->Success();
        } else if (method == "notify") {
          const auto* map =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (map == nullptr) {
            result->Error("bad_arguments", "A map is required.");
            return;
          }
          if (!Notify(StringArgument(*map, "chat"),
                      Widen(StringArgument(*map, "title")),
                      Widen(StringArgument(*map, "body")))) {
            result->Error("no_tray", "No tray icon to notify from.");
            return;
          }
          result->Success();
        } else if (method == "dismissNotification") {
          const auto* chat = std::get_if<std::string>(call.arguments());
          if (chat != nullptr && *chat == notified_chat_ && tray_added_) {
            tray_icon_.uFlags = NIF_INFO;
            tray_icon_.szInfo[0] = L'\0';
            tray_icon_.szInfoTitle[0] = L'\0';
            Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
            notified_chat_.clear();
          }
          result->Success();
        } else if (method == "quit") {
          SetTray(false, L"");
          result->Success();
          PostMessage(GetHandle(), WM_CLOSE, 0, 0);
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetTray(bool enabled, const std::wstring& tooltip) {
  close_to_tray_ = false;
  if (tray_added_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
    tray_added_ = false;
  }
  if (!enabled) return;
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  tray_icon_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcsncpy_s(tray_icon_.szTip, tooltip.c_str(), _TRUNCATE);
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) == TRUE;
  // Closing hides the window only when the tray icon is there to bring it
  // back.
  close_to_tray_ = tray_added_;
}

bool FlutterWindow::Notify(const std::string& chat, const std::wstring& title,
                           const std::wstring& body) {
  if (!tray_added_) return false;
  tray_icon_.uFlags = NIF_INFO;
  tray_icon_.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
  tray_icon_.hBalloonIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcsncpy_s(tray_icon_.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(tray_icon_.szInfo, body.empty() ? L" " : body.c_str(), _TRUNCATE);
  notified_chat_ = chat;
  return Shell_NotifyIconW(NIM_MODIFY, &tray_icon_) == TRUE;
}

void FlutterWindow::ShowFromTray() {
  HWND window = GetHandle();
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window);
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING, kTrayShow, tray_show_label_.c_str());
  AppendMenuW(menu, MF_STRING, kTrayQuit, tray_quit_label_.c_str());
  POINT point;
  GetCursorPos(&point);
  // The menu closes when clicking elsewhere only if the window is in front.
  SetForegroundWindow(GetHandle());
  UINT chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, point.x,
                               point.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  if (chosen == kTrayShow) {
    ShowFromTray();
  } else if (chosen == kTrayQuit) {
    // Dart saves and stops first, then asks for quit.
    if (window_channel_) {
      window_channel_->InvokeMethod("quitRequested", nullptr);
    } else {
      PostMessage(GetHandle(), WM_CLOSE, 0, 0);
    }
  }
}

void FlutterWindow::OnDestroy() {
  SetTray(false, L"");
  window_channel_ = nullptr;
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_CLOSE:
      if (close_to_tray_) {
        // Conest keeps running in the tray.
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          ShowFromTray();
          return 0;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayMenu();
          return 0;
        case NIN_BALLOONUSERCLICK:
          ShowFromTray();
          if (window_channel_ && !notified_chat_.empty()) {
            window_channel_->InvokeMethod(
                "notificationClicked",
                std::make_unique<flutter::EncodableValue>(notified_chat_));
          }
          return 0;
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
