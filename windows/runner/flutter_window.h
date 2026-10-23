#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // dev.conest.conest/window: closing to the tray (setCloseToTray), show
  // and quit; "quitRequested" goes to Dart from the tray menu.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  bool close_to_tray_ = false;
  bool tray_added_ = false;
  NOTIFYICONDATAW tray_icon_ = {};
  std::wstring tray_show_label_ = L"Show Conest";
  std::wstring tray_quit_label_ = L"Quit";
  // The chat of the notification last shown from the tray icon.
  std::string notified_chat_;

  void SetTray(bool enabled, const std::wstring& tooltip);
  void ShowFromTray();
  void ShowTrayMenu();
  bool Notify(const std::string& chat, const std::wstring& title,
              const std::wstring& body);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
