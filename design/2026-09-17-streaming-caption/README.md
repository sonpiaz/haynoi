# Streaming caption mockup — 17/09 (sửa sau đối chiếu frame_04)

**Không sửa `Sources/`.** Video: `~/.watch/960d0b1a2bc6/frames/frame_04.jpg`.

## (1) Vị trí — hai biến thể, Sơn chọn

Video + brief: pill **đáy, giữa, ngay trên Dock**. Orb Haynoi hiện tại: **trên giữa**, dưới menu bar (`FloatingBar.swift:224–228`). Không tự chọn thay Sơn.

| | File | Khi nào |
|---|---|---|
| **Đáy (mặc định, theo video)** | `state-1.png` … `state-6.png` | `mockup.html` hoặc `?pos=bottom` |
| **Trên (orb đang chạy)** | `state-1-top.png` … `state-6-top.png` | `?pos=top` hoặc phím **T** |

Đáy: `bottom: 72px` — không đè Dock. Trên: 10px dưới menu bar — không đè Control Center.

## (2) Chữ đậm = phần mới chưa chốt

Video frame_04: `That looks great.` thường + **`Let's make the`** đậm — đuôi vừa nghe, chưa chốt.

Không còn đậm từ khóa (`config` / `npm run build`).

| Trạng thái | Chữ |
|---|---|
| 2 Đang nói | Đã chốt: regular. Đuôi mới: **đậm**. Caret. |
| 3 Chốt câu | Cả câu regular — **bỏ đậm**. Giữ ~0,6s. |
| 6 Câu dài | Cắt đầu, đuôi chưa chốt **đậm**. |

Dấu Việt: từ đã chốt không vẽ lại.

## Sáu trạng thái (đáy)

| File | Hiện | Biến mất khi |
|---|---|---|
| `state-1.png` | Orb, chưa chữ | Giữ phím >100ms |
| `state-2.png` | Đuôi **đậm** + caret | Thả phím |
| `state-3.png` | Câu chắc, hết đậm, ~0,6s | → 4 |
| `state-4.png` | + `→ Mandeck` | Insert xong |
| `state-5.png` | Lỗi (A/B/C: im / mic / mạng) | ~1,2s |
| `state-6.png` | Câu dài, cắt đầu, đuôi đậm | như 2 |

Câu dài: 1 dòng, max 56% ngang, cắt đầu. 15px regular.

Còn hỏi: nhãn `→ Mandeck` có cần không.
