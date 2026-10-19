# Leo quyền & tạo user trên WordPress lab

Tài liệu này trả lời hai câu hỏi trên **instance lab local** (WordPress 7.1.3,
PHP 8.4.23, SQLite):

1. Một user quyền thấp (`subscriber`) có leo lên `administrator` được không?
2. Một người **không đăng nhập** có tạo được user khác không?

> Chỉ kiểm thử trên hệ thống bạn sở hữu. Các script trong `bin/` là negative-test
> harness và demo misconfiguration, không phải exploit nhắm hệ thống bên ngoài.

## TL;DR

| Kịch bản | Kết quả | Bằng chứng |
| --- | --- | --- |
| Subscriber → admin qua core (cấu hình mặc định) | **Không có đường** — 22/22 vector bị chặn | `evidence/subscriber-escalation.txt` |
| Người lạ tạo user khi đăng ký đang tắt (mặc định) | **Không** | `evidence/registration-misconfig.txt` |
| Người lạ tạo user khi bật "Anyone can register" | **Có** (subscriber) — đúng thiết kế | `evidence/registration-misconfig.txt` |
| Người lạ tạo **admin** khi `default_role = administrator` | **Có**, kèm đăng nhập wp-admin thành công | `evidence/registration-misconfig.txt` |
| Đoán mật khẩu admin (không rate limit) | Khả thi nếu mật khẩu yếu; lab thật dùng 28 ký tự random | `evidence/credential-and-enumeration.txt` |
| Tải file SQLite qua HTTP trong lab | **Có** (PHP built-in server bỏ qua `.htaccess`) → crack offline nếu mật khẩu yếu | `evidence/sqlite-db-exposure.txt` |

Kết luận ngắn: **không có lỗ hổng "subscriber → admin" trong WordPress core đã
vá**. Đường thực tế luôn đi qua một trong ba nhóm: misconfiguration, credential
yếu/lộ, hoặc thành phần thứ ba có lỗ hổng.

## Môi trường và tài khoản test

| User | Role | Mật khẩu |
| --- | --- | --- |
| `admin` | administrator | random 28 ký tự, trong `.admin-credentials` |
| `lowpriv` | subscriber | random 24 ký tự, trong `.lowpriv-credentials` |
| `weakuser` | subscriber | `Password123!` (cố ý yếu, chỉ để demo crack offline) |

Chạy lại toàn bộ kiểm thử subscriber:

```sh
./bin/subscriber-escalation-tests.sh
```

Script đăng nhập bằng `lowpriv`, tấn công từng interface và **exit != 0** nếu có
bất kỳ vector nào vượt qua capability check.

## 1. Subscriber → admin: những gì đã thử và đều thất bại

`evidence/subscriber-escalation.txt` ghi 22 kết quả `[BLOCKED]`:

- **Màn hình quản trị:** `plugin-install.php`, `plugins.php`, `users.php`,
  `user-new.php`, `theme-editor.php`, `options-general.php`, `update-core.php`,
  `customize.php`, `async-upload.php` → `403`/`500` kèm "not allowed".
- **Role injection qua `profile.php`:** gửi thêm `role=administrator` và
  `wp_capabilities[administrator]=1` → bị bỏ qua, role vẫn `subscriber`.
- **Sửa user khác:** `user-edit.php?user_id=1` → "not allowed to edit this user."
- **REST API:** đổi role của chính mình, tạo user mới, đọc/ghi settings,
  liệt kê plugin/theme, tạo post/media → `401/403` với các mã
  `rest_cannot_edit_roles`, `rest_cannot_create_user`, `rest_forbidden`,
  `rest_cannot_create`.
- **XML-RPC:** `wp.getUsers` → `401 "not allowed to list users"`;
  `wp.uploadFile` → `401 "not allowed to upload files"`;
  `wp.editProfile` với `role=administrator` trả `true` nhưng role không đổi;
  `wp.newUser` không tồn tại (`-32601`).
- **Stored XSS qua profile:** `display_name` và `description` chứa
  `<script>`/`<img onerror>` bị KSES loại bỏ (chỉ còn text).

Lý do: mọi hành động trong `wp-admin`, REST và XML-RPC đều đi qua
`current_user_can()` / `map_meta_cap()`. Subscriber chỉ có `read`, `level_0`;
các capability `install_plugins`, `edit_themes`, `create_users`,
`promote_users`, `manage_options` không được cấp.

## 2. Người chưa đăng nhập tạo user

Mặc định WordPress tắt đăng ký (`users_can_register = 0`) và chặn:

```sh
curl -i 'http://127.0.0.1:8899/wp-login.php?action=register'
# 302 -> /wp-login.php?registration=disabled
```

REST `POST /wp/v2/users` không cookie → `401 rest_cannot_create_user`.
XML-RPC không có method tạo user.

Để kiểm chứng hai kịch bản misconfiguration, script tạo **clone throwaway** của
lab (port 8910), không sửa instance chính:

```sh
./bin/registration-misconfig-demo.sh
```

Kết quả thật (`evidence/registration-misconfig.txt`):

```text
-- control: registration disabled (WordPress default) --
Location: .../wp-login.php?registration=disabled
  [BLOCKED] user 'demo_blocked_1037' was not created

-- misconfiguration 1: registration enabled, default role Subscriber --
  role of 'demo_sub_1037': subscriber

-- misconfiguration 2: registration enabled, default role Administrator --
  role of 'demo_admin_1037': administrator
  [EXPLOIT] logged into wp-admin as 'demo_admin_1037' (registration email simulated)

== RESULT: unauthenticated request created an Administrator ==
```

Điểm quan trọng: khi `default_role` bị đặt sai thành Administrator, **một POST
không cần đăng nhập** tạo tài khoản admin; kẻ tấn công dùng email của mình để
nhận thư đăng ký rồi đăng nhập. Script mô phỏng bước nhận email (mailer local
không gửi được) bằng cách đặt mật khẩu cho tài khoản mới rồi đăng nhập thật vào
`wp-admin`.

Bình thường, đăng ký mở chỉ tạo `subscriber` — không leo quyền, nhưng vẫn là
"tạo user khác" không cần đăng nhập.

## 3. Đường thực tế leo lên admin: credential + enumeration

### 3.1 Username enumeration

Ba nguồn lộ username admin, không cần đăng nhập:

| Nguồn | Kết quả |
| --- | --- |
| `wp-login.php` sai mật khẩu | user tồn tại: "password you entered ... is incorrect"; user không tồn tại: "not registered on this site" |
| `wp-login.php?action=lostpassword` | user không tồn tại: "There is no account with that username or email address." |
| `/?author=1` và `/author/admin/` | `200`, lộ slug `admin` |
| `/?rest_route=/wp/v2/users` | trả `[{"id":1,"slug":"admin",...}]` |

Chi tiết trong `evidence/credential-and-enumeration.txt`.

### 3.2 Không có rate limit / lockout

12 lần đăng nhập sai liên tiếp trên clone: tất cả `HTTP 200`, đều có
`login_error`, không `429`, không khoá tài khoản; đăng nhập đúng ngay sau đó
vẫn thành công. XML-RPC cũng không giới hạn số request.

`system.multicall` **không** khuếch đại guessing trên phiên bản này: nếu một
lời gọi sai đứng trước, các lời gọi sau trong cùng batch đều fail (thử nghiệm
`w-c` cho 2 faults, 0 success). Kẻ tấn công vẫn có thể gửi nhiều request riêng.

### 3.3 Khi mật khẩu admin yếu

Trên clone, admin được đặt mật khẩu demo yếu `Lab-Demo-Weak-1` (clone đã bị
xoá). Ba lần thử qua XML-RPC:

```text
candidate 1 (Password123!)    -> fail
candidate 2 (letmein)         -> fail
candidate 3 (Lab-Demo-Weak-1) -> SUCCESS (wp.getUsersBlogs trả dữ liệu blog)
```

Trên lab thật, mật khẩu admin là 28 ký tự random; các lần đoán đều thất bại
(12 lần với mật khẩu sai trên clone, không lockout) và không thể brute force
trong thời gian hợp lý. Đây là khác biệt giữa "có cơ chế đoán" và "đoán thành
công".

## 4. Rò rỉ database SQLite trong lab

`wp-content/database/.ht.<random>/.ht.sqlite` nằm trong web root. Drop-in tạo
`.htaccess` với `DENY FROM ALL`, nhưng **PHP built-in server bỏ qua `.htaccess`**,
nên trong lab file tải được không cần đăng nhập:

```text
GET /wp-content/database/.ht.c25ad.../.ht.sqlite
  -> HTTP 200, 491520 bytes, header "SQLite format 3"
```

Hệ quả:

- Trích được `user_login`, `user_email`, `user_pass` của mọi user.
- Hash dùng `$wp$2y$12$...` (bcrypt cost 12). Xác minh offline bằng
  `wp_check_password()`: `weakuser` + `Password123!` → `true`;
  `admin` + `Password123!` → `false`.
- Với mật khẩu yếu, hash có thể bị crack offline → chiếm admin.

Giới hạn khai thác: tên thư mục `.ht.<32 hex>` sinh ngẫu nhiên
(`random_bytes`), nên không đoán được từ xa. Cần thêm directory listing, file
backup, log lộ path, hoặc quyền đọc filesystem. Trên Apache, `.htaccess` chặn;
trên nginx/cấu hình sai thì có thể lộ. Chi tiết: `evidence/sqlite-db-exposure.txt`.

## 5. Vì sao không có "phép màu" subscriber → admin

- Capability là hàng rào duy nhất; không có tham số HTTP nào được tin tưởng.
- Nonce chỉ chống CSRF, **không** thay thế capability check.
- Auth cookie là HMAC của user ID + session token + salt trong `wp-config.php`;
  không thể tự chế cookie nếu không có salt/session token.
- Password reset key lưu dạng hash, không lộ qua HTTP.
- KSES loại HTML với user thiếu `unfiltered_html`, nên stored XSS qua profile
  không hoạt động (đã kiểm chứng).

Các đường thực tế ngoài core, nếu có:

1. **Plugin/theme lỗi thời** có lỗ hổng leo quyền hoặc SQLi (kiểm tra phiên bản
   và CVE tương ứng; lab này không cài plugin thứ ba).
2. **Lộ credential**: backup, `.env`, `wp-config.php.bak`, log, DB như mục 4.
3. **Email takeover** của admin → dùng lost-password để đặt lại mật khẩu.
4. **Chiếm session admin** qua XSS trên một plugin/theme không escape.
5. **Misconfiguration**: đăng ký mở + default role admin (mục 2), hoặc cấp
   Administrator tràn lan.

## 6. Hardening

```php
// wp-config.php
define( 'DISALLOW_FILE_MODS', true );   // chặn cài/sửa plugin-theme
define( 'DISALLOW_FILE_EDIT', true );   // chặn editor
```

- Để `users_can_register = 0`, hoặc nếu cần mở: `default_role = subscriber`
  (tuyệt đối không để `administrator`), bật xác minh email, chống spam.
- Mật khẩu admin mạnh/ngẫu nhiên + 2FA; không dùng lại mật khẩu.
- Rate limit login + XML-RPC, hoặc tắt XML-RPC nếu không dùng:
  `add_filter( 'xmlrpc_enabled', '__return_false' );`
- Giới hạn `/wp-admin`, `wp-login.php`, `xmlrpc.php` theo IP/VPN.
- Chặn truy cập `wp-content/database/` ở web server; không dùng built-in server
  hay nginx thiếu rule trong production.
- Tắt author enumeration nếu cần (`?author=` redirect), hạn chế REST users.
- Giám sát user mới, thay đổi role, `active_plugins`, toàn vẹn file.
- Nguyên tắc least privilege: không cấp Administrator cho biên tập viên.

## 7. Repro & dọn dẹp

```sh
./bin/create-lowpriv.sh                 # tạo subscriber lowpriv (idempotent)
./bin/subscriber-escalation-tests.sh    # 22 vector, exit 0 nếu tất cả bị chặn
./bin/registration-misconfig-demo.sh    # clone + tạo admin không đăng nhập
```

Xoá user demo trên lab chính (tuỳ chọn):

```sh
bin/php bin/wp-cli.phar user delete lowpriv weakuser --yes --path=/workspace/lab/wordpress
rm -f .lowpriv-credentials .lowpriv-cookies.txt
```

Dừng server lab: `./bin/stop-server.sh`.

