# 🖨️ Canon LBP2900 CAPT Toolkit — LBP2900 / LBP2900B trên Ubuntu & Linux Mint

**Repo:** [github.com/brucenguyen1102/Canon-LBP2900-CAPT-Toolkit](https://github.com/brucenguyen1102/Canon-LBP2900-CAPT-Toolkit)

Bộ công cụ tự động cài đặt, sửa lỗi và chia sẻ máy in Canon LBP2900/2900B (giao thức CAPT độc quyền) trên các bản Linux hiện đại — dùng driver mã nguồn mở thay thế thay vì driver Canon chính hãng đã cũ và khó cài.

Toàn bộ thao tác được gói gọn trong **một script bash duy nhất**, có menu tương tác, tự backup trước khi sửa hệ thống, và có thể **giảm phụ thuộc GitHub** khi cài đặt.

---

## ✨ Tính năng chính

- **Cài driver thay thế:** dùng bản [ValdikSS/captdriver](https://github.com/ValdikSS/captdriver) (nhánh `val`, có *page-streaming*) thay cho driver Canon chính hãng — build và cài tự động, không cần thư viện 32-bit (i386) cũ.
- **Hoặc cài driver Canon chính hãng v2.71:** mục 1 cho phép chọn cài driver chính hãng từ gói `linux-capt-drv-v271-uken.tar.gz` đặt cạnh script — tự động cài thư viện 32-bit (i386) cần thiết, bật daemon `ccpd`, khôi phục module `usblp`. Hai loại driver **loại trừ lẫn nhau**: chọn cài driver nào thì script tự gỡ sạch driver kia trước (cài chính hãng → gỡ captdriver; cài custom → gỡ `cndrvcups-*`/`ccpd`).
- **Tự vá lỗi treo máy khi in tài liệu phức tạp:** vá lỗi race condition trong CUPS USB backend ([OpenPrinting/cups#1461](https://github.com/OpenPrinting/cups/issues/1461)) khiến job in bị treo im lặng khi in tài liệu nhiều hình ảnh.
- **Sửa dứt điểm lỗi kẹt engine ở job thứ 5 (`captd`):** đây là lỗi nặng nhất của driver mã nguồn mở — cứ đến **đúng job thứ 5** kể từ lúc bật máy in là engine kẹt cứng (`ReserveUnit failed 0x8c`), phải tắt/bật nguồn máy in mới in tiếp được. Nguyên nhân: `rastertocapt` là *filter* của CUPS, còn CUPS USB backend **mở rồi đóng lại kết nối USB cho từng job**; driver Canon thật (cả Windows lẫn Linux) không bao giờ bị vì chúng giữ **một phiên USB liên tục** qua mọi job (Canon dùng daemon `ccpd`). Toolkit này dựng lại đúng kiến trúc đó bằng `captd` (daemon giữ phiên USB) + `capt-backend` (CUPS backend `capt:` thay cho `usb://`), kèm 4 file nguồn captdriver đã vá giao thức cho khớp driver Canon Linux thật (nhịp heartbeat `SetJobInfo2`, `GetExtendedStatus` ×2 trước mỗi `ReserveUnit`, sửa vài byte payload, và đọc đủ byte phản hồi thay vì chấp nhận *short read*). **Bắt buộc đủ cả 4 phần** — thiếu bất kỳ phần nào là lỗi job 5 quay lại. Xem `captd-persistent-daemon/README.md`.
- **Driver đã được gia cố thêm (engine hardening):** sửa các vòng lặp chờ trạng thái có thể treo vô thời hạn, và ghi log chẩn đoán chi tiết hơn khi có lỗi. Xem `captdriver-engine-hardening.patch` để biết chi tiết từng thay đổi. (Bản vá này ra đời *trước* khi tìm ra nguyên nhân gốc ở trên — nó giảm nhẹ triệu chứng nhưng **không** tự mình sửa được lỗi job 5.) Phần gia cố này nằm trong `captd-persistent-daemon/` (`capt-status.c`, `capt-status.h`, `generic-ops.c`) và được script ghi đè vào mã nguồn lúc build — **không** dựa vào việc tarball đóng gói sẵn đã được gia cố hay chưa, vì GitHub Action tự động làm mới tarball đó từ upstream mỗi ngày và sẽ ghi đè mất phần gia cố.
- **Dọn sạch cài đặt cũ:** gỡ driver Canon độc quyền cũ (`ccpd`, `cndrvcups`), hàng đợi CUPS cũ, udev rules cũ trước khi cài lại.
- **Tự xử lý xung đột USB:** tắt `ipp-usb`, gỡ module `usblp` đang giữ thiết bị, tạo udev rule riêng cho máy in.
- **Tự chia sẻ qua mạng LAN:** cấu hình CUPS/IPP, mở cổng firewall (nếu `ufw` đang bật), bật `avahi-daemon` để các máy khác tự dò tìm máy in.
- **Tự khắc phục sự cố:** phát hiện và tự reset phiên USB khi máy in báo "không phản hồi", tự thử lại kèm hướng dẫn thủ công nếu vẫn không được.
- **Có thể rollback:** khôi phục nhanh bản filter/backend gốc nếu bản vá gây ra vấn đề mới.
- **Bật log chi tiết vĩnh viễn (LogLevel debug):** script tự đặt CUPS ghi log chi tiết nhất (`/var/log/cups/error_log`) ngay khi cài — nếu người dùng nào đó gặp sự cố sau này, chỉ cần gửi file log này là có đủ dữ liệu để phân tích, không cần bật debug thủ công rồi tái hiện lại lỗi. Đánh đổi: file log sẽ lớn hơn bình thường theo thời gian (logrotate hệ thống vẫn tự xoay vòng như thường lệ).
- **Hỗ trợ cả máy khách Windows:** có sẵn script `.bat`/`.ps1` tự động thêm máy in qua mạng, không cần cài driver Canon trên Windows.
- **Giảm phụ thuộc GitHub:** đặt 2 file mã nguồn/patch đóng gói sẵn cùng thư mục là script không cần tải trực tiếp từ GitHub (xem lưu ý về mạng bên dưới).

---

## 📋 Yêu cầu

- Ubuntu (khuyến nghị các bản dựa trên `noble` 24.04 — phần vá lỗi CUPS backend dùng dòng `deb-src` của noble) hoặc Linux Mint (script tự nhận diện file nguồn riêng của Mint).
- Quyền **root/sudo** (script tự động `sudo` lại chính nó nếu chưa chạy bằng quyền root).
- Máy in **Canon LBP2900 / LBP2900B** cắm qua cổng **USB** (vendor:product `04a9:2676`).
- **Kết nối Internet tới kho gói Ubuntu/Mint** (`apt-get install`/`apt-get build-dep`) — script luôn cần cài các gói phụ thuộc lúc build (`build-essential`, `libcups2-dev`, `cups-ppdc`, `avahi-daemon`...) dù có dùng chế độ đóng gói sẵn hay không. Chế độ đóng gói sẵn (xem mục dưới) chỉ bỏ được phần tải từ **GitHub**, không thay thế được kết nối tới kho Ubuntu/Mint.

---

## 🚀 Cài đặt nhanh

```bash
# 1. Clone repo vào một thư mục trên máy chủ Linux (nơi cắm máy in qua USB)
git clone https://github.com/brucenguyen1102/Canon-LBP2900-CAPT-Toolkit.git
cd Canon-LBP2900-CAPT-Toolkit

# 2. Chạy script với quyền root (menu tương tác)
sudo bash may-in-lbp2900.sh
```

Script cũng hỗ trợ chạy thẳng một mục trong menu, bỏ qua tương tác:

```bash
# Chạy thẳng mục 1, tự động chọn mặc định cho mọi câu hỏi (driver custom)
sudo bash may-in-lbp2900.sh --yes 1

# Chạy thẳng mục 1 với driver Canon CHÍNH HÃNG v2.71 (cần file
# linux-capt-drv-v271-uken.tar.gz đặt cạnh script)
sudo bash may-in-lbp2900.sh --yes --official 1

# Khôi phục nhanh nếu mục 5 (vá lỗi) gây vấn đề mới (nâng cao, không có trong menu)
sudo bash may-in-lbp2900.sh --rollback-cups-backend
sudo bash may-in-lbp2900.sh --rollback-captdriver-filter
```

---

## 📜 Menu chính

Chạy `sudo bash may-in-lbp2900.sh` sẽ hiện menu 6 mục sau:

| # | Chức năng |
|---|-----------|
| **1** | Gỡ và cài lại LBP2900 (máy này, cắm trực tiếp qua USB) — hỏi chọn **driver custom** (ValdikSS/captdriver + vá lỗi CUPS backend) hoặc **driver Canon chính hãng v2.71** (từ gói `linux-capt-drv-v271-uken.tar.gz`); tự gỡ driver còn lại nếu đã cài, chia sẻ qua LAN, in thử tự động |
| **2** | Cài LBP2900 qua mạng từ máy khác (**Linux**) — kết nối tới máy chủ đã chia sẻ ở mục 1 |
| **3** | Cài LBP2900 qua mạng từ máy khác (**Windows**) — hiện hướng dẫn tóm tắt (xem thêm file HTML đi kèm) |
| **4** | Sửa lỗi "máy in không phản hồi" (CAPT no reply) — tự động reset phiên USB bằng phần mềm |
| **5** | Vá lỗi treo khi in tài liệu phức tạp (nhiều hình ảnh) — áp dụng lại 2 bản vá cho máy **đã cài LBP2900 từ trước**, không cần cài lại từ đầu |
| **6** | Thoát |

---

## 📦 Giảm phụ thuộc GitHub (bundle mã nguồn sẵn)

Nếu đặt 2 file sau **cùng thư mục** với `may-in-lbp2900.sh` trước khi chạy, script sẽ tự dùng bản đóng gói sẵn thay vì tải từ GitHub:

- `captdriver-valdikss-val.tar.gz` — mã nguồn driver ValdikSS/captdriver (nhánh `val`)
- `cups-1461-usb-backend-fix.patch` — patch vá lỗi CUPS USB backend (OpenPrinting/cups#1461)

Ngoài ra, nếu muốn cài **driver Canon chính hãng v2.71** ở mục 1, cần đặt thêm file sau cạnh script (**bắt buộc** — driver Canon có bản quyền riêng nên script không tự tải về được):

- `linux-capt-drv-v271-uken.tar.gz` — CAPT Printer Driver for Linux Version 2.71 (tải từ trang Canon)

> ⚠️ **Đây KHÔNG phải chế độ offline hoàn toàn.** Script vẫn luôn chạy `apt-get update`/`apt-get install`/`apt-get build-dep` để cài các gói phụ thuộc lúc build (`build-essential`, `libcups2-dev`, `cups-ppdc`, `avahi-daemon`...) và bước `apt-get source cups` (tải mã nguồn gói CUPS đang cài trên máy) — tất cả đều cần kết nối tới kho Ubuntu/Mint, không liên quan GitHub nên không đóng gói sẵn được. Bundle 2 file trên chỉ giúp bỏ được phần tải trực tiếp từ GitHub.

---

## 🌐 Kết nối từ máy khác (Linux/Windows)

Sau khi máy chủ Linux đã chạy xong **mục 1** (bật chia sẻ qua LAN), các máy khác trong cùng mạng có thể dùng chung máy in:

- **Máy Linux khác:** chạy `sudo bash may-in-lbp2900.sh`, chọn **mục 2**, nhập IP máy chủ.
- **Máy Windows:** copy **cả 2 file** `cai-may-in-lbp2900-windows.bat` và `cai-may-in-lbp2900-windows.ps1` vào cùng một thư mục, double-click file `.bat` (tự xin quyền Administrator), nhập IP máy chủ khi được hỏi. Windows dùng driver IPP có sẵn, **không cần cài driver Canon**.

Xem hướng dẫn đầy đủ, trực quan (có sơ đồ, tab Linux/Windows, FAQ) trong file **[`huong-dan-ket-noi-may-in.html`](./huong-dan-ket-noi-may-in.html)** — mở bằng trình duyệt trên máy cần kết nối.

---

## 🛠️ Xử lý sự cố

Máy in Canon LBP2900 là dòng khá cũ, thỉnh thoảng "kẹt" khi nhận lệnh in. Chạy `sudo bash may-in-lbp2900.sh` trên **máy chủ** (nơi cắm máy in) rồi chọn:

- **Mục 4 — "Máy in không phản hồi":** tự động reset phiên giao tiếp USB bằng phần mềm (không cần rút/cắm dây).
- **Mục 5 — "Treo khi in tài liệu phức tạp":** áp dụng lại 2 bản vá (CUPS backend + driver captdriver) cho máy đã cài từ trước.

Nếu cả hai vẫn không hết: **tắt nguồn máy in, đợi ~10 giây, bật lại** — đây là bước cuối cùng gần như luôn hiệu quả với dòng máy in này (do bộ điều khiển bên trong máy in bị treo, không phải lỗi cài đặt).

**Muốn báo lỗi để phân tích sâu hơn?** Script đã tự bật sẵn log chi tiết nhất của CUPS (`LogLevel debug`), nên chỉ cần gửi kèm nội dung file `/var/log/cups/error_log` (đoạn quanh thời điểm gặp lỗi) khi mở issue — không cần bật debug thủ công hay chờ tái hiện lại lỗi.

---

## ❓ Câu hỏi thường gặp

<details>
<summary>Máy chủ Linux có cần bật liên tục không?</summary>
Có. Máy chủ là nơi thực sự nói chuyện với máy in qua USB, nên phải đang bật và kết nối mạng thì các máy khác mới in được.
</details>

<details>
<summary>Có cần cài driver Canon trên máy khách (Windows/Linux) không?</summary>
Không. Máy chủ Linux đã xử lý việc chuyển đổi sang định dạng CAPT mà máy in hiểu. Máy khách chỉ cần driver IPP chuẩn có sẵn trong hệ điều hành.
</details>

<details>
<summary>Địa chỉ IP máy chủ thay đổi thì sao?</summary>
Kiểm tra IP mới trên máy chủ (lệnh <code>ip a</code>), rồi nhập lại IP mới khi cài trên máy khách. Nên đặt IP tĩnh cho máy chủ trên router để tránh phải làm lại.
</details>

<details>
<summary>In từ nhiều máy cùng lúc có sao không?</summary>
Được — CUPS tự xếp hàng và in tuần tự từng job một, không cần người dùng tự chờ nhau. Qua điều tra thực tế, nguyên nhân "kẹt" máy in dòng này thường không phải do gửi lệnh cùng lúc, mà do <b>nội dung phức tạp/nhiều hình ảnh</b> khiến bộ điều khiển bên trong máy in bị treo — bản vá driver đã gia cố (xem mục Tính năng chính) giúp giảm khả năng này, nhưng nếu vẫn xảy ra thì cần tắt/bật nguồn máy in (mục 4/5 trong menu chỉ xử lý được phần mềm, không phải lỗi cứng bên trong máy).
</details>

*(Xem thêm FAQ chi tiết hơn trong file `huong-dan-ket-noi-may-in.html`.)*

---

## 📂 Cấu trúc file trong repo

| File | Vai trò |
|---|---|
| `may-in-lbp2900.sh` | Script chính — menu tương tác, cài/gỡ/sửa lỗi/chia sẻ máy in (chạy trên máy chủ Linux) |
| `huong-dan-ket-noi-may-in.html` | Trang hướng dẫn HTML trực quan cho người dùng cuối, mở bằng trình duyệt |
| `cai-may-in-lbp2900-windows.bat` | File khởi chạy nhanh cho Windows — double-click để tự nâng quyền Admin và gọi file `.ps1` |
| `cai-may-in-lbp2900-windows.ps1` | Script PowerShell tự động thêm máy in qua IPP từ máy chủ Linux, kèm in thử |
| `captdriver-valdikss-val.tar.gz` | Mã nguồn driver ValdikSS/captdriver (nhánh `val`) đóng gói sẵn — dùng để giảm phụ thuộc GitHub. Đây là bản **gốc upstream** (GitHub Action tự làm mới hằng ngày); mọi bản vá riêng đều nằm trong `captd-persistent-daemon/` và được ghi đè vào lúc build |
| `captdriver-engine-hardening.patch` | Tài liệu diff các thay đổi gia cố thêm vào driver (so với bản gốc ValdikSS) — không cần áp dụng thủ công, script tự ghi đè các file tương ứng từ `captd-persistent-daemon/` |
| `cups-1461-usb-backend-fix.patch` | Patch vá lỗi race condition CUPS USB backend (OpenPrinting/cups#1461) đóng gói sẵn — dùng để giảm phụ thuộc GitHub |
| `linux-capt-drv-v271-uken.tar.gz` | Driver Canon chính hãng v2.71 (CAPT Printer Driver for Linux) — dùng khi chọn cài driver chính hãng ở mục 1 |

---

## 🐛 Báo lỗi / Đóng góp

Gặp lỗi hoặc có đề xuất cải tiến? Mở issue tại [github.com/brucenguyen1102/Canon-LBP2900-CAPT-Toolkit/issues](https://github.com/brucenguyen1102/Canon-LBP2900-CAPT-Toolkit/issues).

> ⚠️ Toolkit này chỉ hỗ trợ chính thức **Canon LBP2900 / LBP2900B**. Các model khác (LBP3000, LBP3010/3018/3050...) về lý thuyết có thể hoạt động nhờ driver nền [ValdikSS/captdriver](https://github.com/ValdikSS/captdriver) nhưng **chưa được kiểm chứng** với script này (script đang hardcode mã USB `04a9:2676` riêng cho LBP2900). LBP3200/LBP3300 **không được hỗ trợ** bởi driver mã nguồn mở này.

---

## 🔧 Ghi chú kỹ thuật / Credits

- Driver thay thế: [ValdikSS/captdriver](https://github.com/ValdikSS/captdriver) (nhánh `val`, hỗ trợ page-streaming).
- Bản vá CUPS: [OpenPrinting/cups#1461](https://github.com/OpenPrinting/cups/issues/1461).
- Script tự backup mọi file/binary quan trọng trước khi ghi đè (filter driver, CUPS backend, `cupsd.conf`) và có sẵn cờ `--rollback-*` để khôi phục nhanh nếu cần.

**Design by Bruce Nguyen from [CCTVWIKI.COM](https://cctvwiki.com) và Claude Code Max**

---

## 📄 License


