# BandPulse — Giám sát & Dự báo Pin Huawei Band 11 (iOS `.ipa`)

Ứng dụng iOS đọc trực tiếp mức pin chuẩn **Bluetooth Low Energy (`0x180F` / `0x2A19`)** từ **Huawei Band 11** song song với app **Huawei Health**, tự động tách chu kỳ **Sạc / Xả** và dự báo thời gian sạc đầy / ngày giờ hết pin.

---

## Tính năng chính
- **Đọc pin BLE tự động (`CoreBluetooth`):** Kết nối lại thiết bị đang ghép đôi sẵn với iOS (`retrieveConnectedPeripherals`), lắng nghe `Notify` và đọc định kỳ `0x2A19` kèm hỗ trợ chạy nền (`bluetooth-central` State Restoration & `BGAppRefreshTask`).
- **Tách chu kỳ Sạc / Xả thông minh:** Tự nhận diện khi pin tăng (đang sạc) hoặc giảm (đang xả), hỗ trợ nút đánh dấu cắm/rút đế sạc thủ công.
- **Dự báo Sạc & Xả:**
  - *Khi đang sạc:* Tính tốc độ nạp (`%/phút`), tính cả pha sạc chậm từ 80% → 100%, ước tính phút còn lại & giờ đầy.
  - *Khi đang dùng:* Pha trộn tốc độ xả thực tế gần nhất với lịch sử các chu kỳ trước và profile Band 11 (*Tiết kiệm ~14 ngày / Thường ~8 ngày / AOD ~3 ngày*).
- **Biểu đồ & Xuất CSV:** Biểu đồ `SwiftCharts` kèm đường dự báo nét đứt và xuất lịch sử ra file `.csv`.
- **Widget màn hình chính & màn hình khóa (`WidgetKit`)** + **Thông báo nhắc rút sạc / pin yếu**.

---

## Cách build file `.ipa` từ Windows & cài qua SideStore

Vì máy Windows không có Xcode, bạn chỉ cần đẩy thư mục này lên **GitHub** (repo Private hay Public đều được) để GitHub Actions tự build miễn phí trên macOS:

1. **Tạo repo trên GitHub** và push toàn bộ thư mục `HuaweiBandBatteryMonitor` lên nhánh `main`:
   ```powershell
   cd "C:\Users\My PC\.gemini\antigravity\scratch\HuaweiBandBatteryMonitor"
   git init
   git add .
   git commit -m "Initial BandPulse iOS app"
   git branch -M main
   git remote add origin https://github.com/<TEN_GITHUB_CUA_BAN>/HuaweiBandBatteryMonitor.git
   git push -u origin main
   ```
2. Mở tab **Actions** trên GitHub → chọn workflow **Build iOS IPA (SideStore)** (chạy tự động sau khi push, mất khoảng ~3–5 phút).
3. Khi chạy xong (dấu tích xanh), cuộn xuống mục **Artifacts** và tải file **`BandPulse-SideStore-IPAs.zip`**. Giải nén ra bạn sẽ thấy **2 file `.ipa`**:
   - **`HuaweiBandBattery-WithWidget.ipa`**: Bản đầy đủ có Widget màn hình chính/khóa *(tốn 2 App ID trên Apple ID miễn phí)*.
   - **`HuaweiBandBattery-SingleAppID.ipa`**: Bản gọn không kèm Widget *(chỉ tốn 1 App ID nếu SideStore của bạn gần đầy giới hạn 3 App)*.
4. Chép file `.ipa` vào iPhone (qua iCloud Drive / LocalSend / Telegram / Drive) → mở bằng **SideStore** (nhớ bật **StosVPN** trước khi cài) → bấm cài đặt.

---

## Lưu ý khi dùng trên iPhone
- Mở app lần đầu: cấp quyền **Bluetooth** và **Thông báo** → app sẽ tự tìm `HUAWEI Band 11` đang kết nối với iPhone.
- Không vuốt tắt hoàn toàn app khỏi trình đa nhiệm để iOS giữ khả năng đánh thức `CoreBluetooth` chạy nền tốt hơn.
- Nhớ mở SideStore refresh app mỗi 7 ngày như các app sideload thông thường.
