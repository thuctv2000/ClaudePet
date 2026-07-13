# Desktop Pet for macOS

A small transparent desktop mascot that stays visible above normal windows and across Spaces/full-screen apps.

## Run

```sh
swift run
```

Drag the dog by its transparent window background. Click the dog for a short happy animation. Use the paw icon in the menu bar to hide it, enable click-through, or quit.

## Run in Xcode

XcodeGen configuration is included. Generate and open the Xcode project with:

```sh
xcodegen generate
open PetMacOS.xcodeproj
```

Select the **PetMacOS** scheme and press `⌘R`. The app is intentionally a menu-bar app, so look for the paw icon in the menu bar rather than a Dock icon.

## Kết nối với Claude Code

Con pet có thể trở thành "màn hình phụ" cho Claude Code: hiển thị Claude đang làm gì, trả
lời gì, và cho phép **duyệt quyền ngay trên pet** khi bạn đang xem video hay ở tab khác.

Cách hoạt động: khi app chạy, nó mở một HTTP server chỉ trên `127.0.0.1` và ghi cổng + token
vào `~/.petmacos/config.json`. Các *hook* của Claude Code gọi `pet-hook.sh` để gửi sự kiện
tới pet. Với `PreToolUse`, script **chờ** bạn bấm Cho phép/Từ chối trên pet rồi trả quyết
định cho Claude Code — terminal không cần bật lên.

Bật kết nối:

1. Chạy app (`swift run`), tìm biểu tượng bàn chân trên menu bar.
2. Bấm **"Kết nối Claude Code"**. App sẽ:
   - Ghi `~/.petmacos/pet-hook.sh` (đã `chmod +x`).
   - Chèn cấu hình hooks vào `~/.claude/settings.json` (giữ nguyên các cài đặt khác).
3. Mở một phiên Claude Code mới trong terminal và làm việc như bình thường.

Trong menu bar còn có:
- **Chỉ hỏi tool ghi/chạy** — chỉ xin quyền với `Bash/Write/Edit/…`, các tool đọc chỉ báo.
- **Tạm dừng duyệt quyền** — tự động cho phép để đỡ phiền (không hỏi).
- **Ngắt kết nối Claude Code** — gỡ các hook đã chèn khỏi `settings.json`.

Nếu hết thời gian chờ (mặc định 300s) hoặc app không chạy, tool sẽ bị **từ chối an toàn** và
Claude Code không bị treo.

## Animation bằng ảnh (sprite anime)

Con pet có thể thay con chó vẽ sẵn bằng nhân vật anime của bạn. Mỗi **state** là một
chuỗi frame PNG trong suốt, app phát như flipbook. Ảnh nằm **ngoài** app tại
`~/.petmacos/sprites/`, nên đổi/thêm frame **không cần build lại**.

1. Menu bar > **"Mở thư mục sprites"** (app tự tạo sẵn các thư mục + `README.txt`).
2. Thả frame vào từng state, đặt tên theo thứ tự: `idle/idle_000.png`, `idle_001.png`, …
   - States: `idle` (rảnh), `click` (nhấn vào — chạy 1 lần), `thinking`, `working`,
     `talking`, `asking` (xin quyền), `sleep` (kết thúc phiên).
3. Tùy chọn `clip.json` trong mỗi thư mục để chỉnh tốc độ/lặp: `{"fps": 12, "loop": true}`.
4. Menu bar > **"Tải lại sprites"** để áp dụng.

State nào chưa có ảnh sẽ tự dùng frame `idle`; chưa có ảnh nào cả thì dùng con chó vẽ sẵn.

> Lưu ý: nếu dùng art nhân vật có bản quyền (vd nhân vật Genshin) thì chỉ nên dùng cá nhân;
> cân nhắc khi phát hành công khai.

## Build an application bundle

```sh
swift build -c release
```

The executable is placed at `.build/release/PetMacOS`.
