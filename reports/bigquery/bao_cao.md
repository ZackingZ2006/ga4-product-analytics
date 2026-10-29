# KẾT QUẢ PHỄU GA4 TRÊN BIGQUERY

Báo cáo phễu cấp phiên — chỉ số được tính lại và đối chiếu từ CSV.

- Phiên đủ điều kiện: **354,655**
- Phiên bắt đầu phễu: **75,911**
- Phiên hoàn tất phễu: **2,762**
- Chuyển đổi từ lượt xem: **3.6%**

| Bước | Số phiên | Tỷ lệ từ bước trước | Tỷ lệ từ lượt xem |
|---|---:|---:|---:|
| Xem sản phẩm | 75,911 | 100.0% | 100.0% |
| Thêm giỏ | 14,284 | 18.8% | 18.8% |
| Bắt đầu thanh toán | 5,143 | 36.0% | 6.8% |
| Ghi nhận mua hàng | 2,762 | 53.7% | 3.6% |

## Theo thiết bị

| Thiết bị | Xem | Thêm giỏ | Thanh toán | Purchase | View → purchase |
|---|---:|---:|---:|---:|---:|
| desktop | 44,183 | 8,250 | 2,949 | 1,558 | 3.5% |
| mobile | 30,050 | 5,732 | 2,085 | 1,144 | 3.8% |
| tablet | 1,678 | 302 | 109 | 60 | 3.6% |

Các nhóm dưới 100 phiên xem không có trong bảng thiết bị; tổng nhóm có thể thấp hơn tổng phễu. Sự khác biệt giữa nhóm là quan sát, chưa chứng minh nguyên nhân.

Độ nhạy timestamp: strict có **2,762** phiên hoàn tất; weak có **2,818**. Đây là hai chính sách xử lý đồng thời, không xác định được thứ tự thật.

Chế độ: `source`. BigQuery job ID: `job_azoK8yFb8_Va3Fc7oapUVR52kyoB`. Công cụ chỉ kiểm tra tính nhất quán CSV, không xác minh job từ xa.
Phễu là cấp phiên và có thể gồm nhiều sản phẩm; purchase event khác giao dịch đã xác minh. Dataset mẫu đã được làm nhiễu.

![Phễu](funnel.svg)
