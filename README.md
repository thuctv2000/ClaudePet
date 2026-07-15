# ClaudePet — Desktop Pet cho Claude Code trên macOS

Một chú pet trong suốt sống trên màn hình, luôn nổi trên các cửa sổ và đi theo bạn qua mọi Space/full-screen. Pet là "màn hình phụ" cho [Claude Code](https://claude.com/claude-code): hiển thị Claude đang nghĩ/làm/hỏi gì, và cho phép **duyệt quyền ngay trên pet** khi bạn đang xem video hay ở tab khác.

## Cài đặt (khuyên dùng)

1. Tải **PetMacOS-x.y.z.dmg** từ [Releases](https://github.com/thuctv2000/ClaudePet/releases)
2. Mở DMG, kéo **PetMacOS** vào **Applications** (theo mũi tên)
3. Mở app — wizard hướng dẫn tự hiện, bấm **"Kết nối Claude Code"**
4. Mở Claude Code chạy thử một lệnh để thấy pet phản ứng 🐾

App đã ký Developer ID và được Apple notarize — mở được ngay, không bị Gatekeeper chặn. Yêu cầu **macOS 14+**. Máy chưa cài Claude Code? Wizard sẽ chỉ chỗ cài rồi cho kiểm tra lại.

## Tính năng

- **Biểu cảm theo trạng thái Claude Code**: thinking, working, talking, asking (xin quyền), sleeping
- **Task cards**: hoạt động đang chạy, subagent, background task, kết quả hoàn thành
- **Duyệt quyền trên pet**: hook `PreToolUse` chờ bạn bấm Cho phép/Từ chối rồi mới trả quyết định cho Claude Code — terminal không cần bật lên. Hết thời gian chờ (mặc định 300s) hoặc app không chạy thì tool bị **từ chối an toàn**, Claude Code không treo
- **Badge mức sử dụng** Claude (cửa sổ 5 giờ / 1 tuần)
- **Sprite tùy chỉnh**: thay chó vẽ sẵn bằng nhân vật của bạn (xem bên dưới)
- **Tab Chẩn đoán** trong Settings: trạng thái hook/server, kiểm tra kết nối, copy log, cài lại hook

## Cách hoạt động

Khi chạy, app mở một HTTP server chỉ trên `127.0.0.1` (port do OS cấp mỗi lần chạy) và ghi port + token vào `~/.petmacos/config.json`. Nút "Kết nối Claude Code" sẽ:

- Ghi `~/.petmacos/pet-hook.sh` (đã `chmod +x`)
- Chèn cấu hình hooks vào `~/.claude/settings.json` (giữ nguyên các cài đặt khác)

Từ đó mỗi phiên Claude Code mới sẽ gọi `pet-hook.sh` gửi sự kiện tới pet. **"Ngắt kết nối Claude Code"** trong menu bar gỡ sạch các hook đã chèn.

Tùy chọn trong menu bar / Settings:

- **Chỉ hỏi tool ghi/chạy** — chỉ xin quyền với `Bash/Write/Edit/…`, tool đọc chỉ báo
- **Tạm dừng duyệt quyền** — tự cho phép để đỡ phiền
- **Hide pet / Click-through** — ẩn pet hoặc cho chuột xuyên qua

## Sprite tùy chỉnh (anime)

Mỗi **state** là một chuỗi frame PNG trong suốt, app phát như flipbook. Ảnh nằm **ngoài** app tại `~/.petmacos/sprites/` nên đổi frame không cần build lại.

1. Menu bar → **"Mở thư mục sprites"** (app tạo sẵn thư mục + `README.txt`)
2. Thả frame vào từng state, đặt tên theo thứ tự: `idle/idle_000.png`, `idle_001.png`, …
   - States: `idle`, `click` (chạy 1 lần), `thinking`, `working`, `talking`, `asking`, `sleep`
3. Tùy chọn `clip.json` mỗi thư mục: `{"fps": 12, "loop": true}`
4. Menu bar → **"Tải lại sprites"**

State chưa có ảnh sẽ dùng frame `idle`; chưa có ảnh nào thì dùng chó vẽ sẵn.

> Lưu ý: art nhân vật có bản quyền (vd Genshin) chỉ nên dùng cá nhân; cân nhắc khi phát hành công khai.

## Khi có trục trặc

Mở **Settings → tab Chẩn đoán**: xem hook đã cài chưa, server nghe cổng nào, event cuối lúc nào; bấm **Kiểm tra kết nối** (bắn event test qua đúng đường hook thật), **Copy log** để gửi kèm khi báo lỗi, hoặc **Cài lại hook**. Log chi tiết ở `~/.petmacos/events.log`.

## Dành cho developer

```sh
# Chạy nhanh
swift run

# Hoặc mở bằng Xcode (repo dùng XcodeGen)
xcodegen generate
open PetMacOS.xcodeproj   # scheme PetMacOS, ⌘R
```

App là menu-bar app (LSUIElement) — tìm icon bàn chân trên menu bar, không có icon Dock.

```sh
# Test e2e (cần app đang chạy)
tests/e2e_pet_state.sh

# Build bản phân phối: ký Developer ID + DMG (+ notarize với --notarize)
scripts/build-release.sh --notarize
```

Build từ source **không cần** Apple Developer account (Xcode ký ad-hoc chạy local). Muốn tự phát hành bản fork thì cần account của bạn, override identity qua biến môi trường:

```sh
PET_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
PET_TEAM_ID=TEAMID PET_NOTARY_PROFILE=YourProfile \
scripts/build-release.sh --notarize
```