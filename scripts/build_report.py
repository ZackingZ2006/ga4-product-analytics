"""Build a portable report from exported result sets, with strict validation.

This tool does not run BigQuery, verify a remote job, or invent missing results.
Sample mode is watermarked throughout. Standard library only, Python >= 3.9.
"""
import argparse
import csv
from html import escape
import json
import math
from pathlib import Path


def read_csv(path, required):
    with path.open(encoding='utf-8-sig', newline='') as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames or set(required) - set(reader.fieldnames):
            raise ValueError(f'{path.name}: missing columns {sorted(set(required)-set(reader.fieldnames or []))}')
        rows = list(reader)
    if not rows:
        raise ValueError(f'{path.name}: empty export')
    return rows


def number(value, name, allow_null=False):
    if value is None or str(value).strip().lower() in ('', 'null', 'none'):
        if allow_null:
            return None
        raise ValueError(f'{name}: missing numeric value')
    v = float(value)
    if not math.isfinite(v):
        raise ValueError(f'{name}: non-finite value')
    return v


def whole(value, name):
    v = number(value, name)
    if v < 0 or not v.is_integer():
        raise ValueError(f'{name}: expected nonnegative integer')
    return int(v)


def ratio(a, b):
    return None if not b else a / b


def eq(actual, expected, label):
    if actual is None and expected is None:
        return
    if actual is None or expected is None or not math.isclose(actual, expected, rel_tol=1e-8, abs_tol=1e-9):
        raise ValueError(f'{label}: exported {actual!r} differs from recomputed {expected!r}')


def pct(v):
    return '—' if v is None else f'{v * 100:.1f}%'


def load(path):
    kpis = read_csv(path/'07_kpi_overview.csv', ['eligible_sessions','strict_funnel_purchase_sessions','view_to_purchase_rate'])
    if len(kpis) != 1:
        raise ValueError('07_kpi_overview.csv must have exactly one row')
    overall = kpis[0]
    rows = read_csv(path/'08_funnel_steps.csv', ['step','event','sessions','previous_sessions','entrants','step_conversion_rate','entry_conversion_rate'])
    if len(rows) != 4:
        raise ValueError('08_funnel_steps.csv must have exactly four steps')
    rows.sort(key=lambda r: whole(r['step'], 'step'))
    expected_events = ['view_item','add_to_cart','begin_checkout','purchase']
    if [r['event'] for r in rows] != expected_events or [whole(r['step'],'step') for r in rows] != [1,2,3,4]:
        raise ValueError('Unexpected step sequence')
    counts = [whole(r['sessions'], 'sessions') for r in rows]
    if any(a < b for a,b in zip(counts, counts[1:])):
        raise ValueError('Funnel counts increase at a later step')
    eligible = whole(overall['eligible_sessions'], 'eligible_sessions')
    if eligible == 0 or not (eligible >= counts[0] > 0):
        raise ValueError('Funnel entrants must be nonzero and not exceed eligible sessions')
    for i,r in enumerate(rows):
        prev = counts[max(i-1,0)]
        if whole(r['previous_sessions'],'previous_sessions') != prev or whole(r['entrants'],'entrants') != counts[0]:
            raise ValueError('Funnel denominator mismatch')
        eq(number(r['step_conversion_rate'],'step_conversion_rate',True), ratio(counts[i],prev), 'step_conversion_rate')
        eq(number(r['entry_conversion_rate'],'entry_conversion_rate',True), ratio(counts[i],counts[0]), 'entry_conversion_rate')
    if whole(overall['strict_funnel_purchase_sessions'],'strict_funnel_purchase_sessions') != counts[-1]:
        raise ValueError('KPI purchase sessions differ from funnel')
    eq(number(overall['view_to_purchase_rate'],'view_to_purchase_rate',True), ratio(counts[-1],counts[0]), 'overview conversion')
    devices = read_csv(path/'08b_funnel_by_device.csv', ['device_category','view_sessions','cart_sessions','checkout_sessions','purchase_sessions'])
    seen = set()
    for d in devices:
        category = d['device_category']
        if not category or category in seen:
            raise ValueError('Missing or duplicate device category')
        seen.add(category)
        dcounts = [whole(d[k], k) for k in ['view_sessions','cart_sessions','checkout_sessions','purchase_sessions']]
        if dcounts[0] < 100 or any(a < b for a,b in zip(dcounts,dcounts[1:])):
            raise ValueError(f'{category}: inconsistent counts or fewer than 100 entrants')
        for name,a,b in [('view_to_cart_rate',1,0),('cart_to_checkout_rate',2,1),('checkout_to_purchase_rate',3,2),('view_to_purchase_rate',3,0)]:
            if name in d:
                eq(number(d[name],name,True),ratio(dcounts[a],dcounts[b]),f'{category} {name}')
        d['_counts'] = dcounts
    if any(sum(d['_counts'][i] for d in devices) > counts[i] for i in range(4)):
        raise ValueError('Device subgroup total exceeds overall funnel')
    return {'eligible':eligible,'counts':counts,'devices':devices,'overview':overall}


def funnel_svg(data, watermark):
    counts = data['counts']
    labels = ['Xem sản phẩm','Thêm giỏ','Bắt đầu thanh toán','Ghi nhận mua hàng']
    w,h = 1000, 370
    x0, y0, chartw = 280, 60, 620
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" role="img" aria-label="Số phiên từng bước phễu">',
           '<rect width="1000" height="370" fill="#f6f8fb"/>',
           '<text x="32" y="30" font-family="Arial" font-size="18" font-weight="bold" fill="#1b3049">Phễu theo phiên</text>']
    for i,(label,n) in enumerate(zip(labels,counts)):
        y=y0+i*70
        width=chartw*n/counts[0]
        out += [f'<text x="265" y="{y+22}" text-anchor="end" font-family="Arial" font-size="15" fill="#263b55">{escape(label)}</text>',
                f'<rect x="{x0}" y="{y}" width="{width:.2f}" height="33" rx="5" fill="{["#244563","#277c8d","#1b9e91","#73bcae"][i]}"/>',
                f'<text x="{min(x0+width+10,940):.2f}" y="{y+22}" font-family="Arial" font-size="15" fill="#263b55">{n:,} ({pct(ratio(n,counts[0]))})</text>']
    if watermark:
        out.append('<text x="500" y="347" text-anchor="middle" font-family="Arial" font-size="14" font-weight="bold" fill="#a43a32">DỮ LIỆU KIỂM THỬ GIẢ LẬP — KHÔNG PHẢI KẾT QUẢ GA4</text>')
    out.append('</svg>')
    return ''.join(out)


def build(input_dir, output_dir, mode, weak_dir=None, job_id=None):
    data=load(input_dir)
    weak=load(weak_dir) if weak_dir else None
    if weak and (weak['eligible'] != data['eligible'] or any(a < b for a,b in zip(weak['counts'],data['counts']))):
        raise ValueError('Weak-order result must use the same cohort and have counts >= strict counts')
    if mode == 'source' and not job_id:
        raise ValueError('Source mode requires --job-id; this is user-supplied and not remotely verified')
    output_dir.mkdir(parents=True, exist_ok=True)
    watermark = mode == 'fixture'
    name = 'MẪU KIỂM THỬ GIẢ LẬP — KHÔNG PHẢI KẾT QUẢ GA4' if watermark else 'KẾT QUẢ PHỄU GA4 TRÊN BIGQUERY'
    rows = list(zip(['Xem sản phẩm','Thêm giỏ','Bắt đầu thanh toán','Ghi nhận mua hàng'],data['counts']))
    body = [f'# {name}', '', 'Báo cáo phễu cấp phiên — chỉ số được tính lại và đối chiếu từ CSV.', '',
            f"- Phiên đủ điều kiện: **{data['eligible']:,}**", f"- Phiên bắt đầu phễu: **{data['counts'][0]:,}**",
            f"- Phiên hoàn tất phễu: **{data['counts'][3]:,}**", f"- Chuyển đổi từ lượt xem: **{pct(ratio(data['counts'][3],data['counts'][0]))}**", '',
            '| Bước | Số phiên | Tỷ lệ từ bước trước | Tỷ lệ từ lượt xem |', '|---|---:|---:|---:|']
    for i,(label,n) in enumerate(rows):
        body.append(f'| {label} | {n:,} | {pct(ratio(n,data["counts"][max(0,i-1)]))} | {pct(ratio(n,data["counts"][0]))} |')
    body += ['', '## Theo thiết bị', '', '| Thiết bị | Xem | Thêm giỏ | Thanh toán | Purchase | View → purchase |', '|---|---:|---:|---:|---:|---:|']
    for d in data['devices']:
        a,b,c,e=d['_counts']
        body.append(f'| {d["device_category"]} | {a:,} | {b:,} | {c:,} | {e:,} | {pct(ratio(e,a))} |')
    body += ['', 'Các nhóm dưới 100 phiên xem không có trong bảng thiết bị; tổng nhóm có thể thấp hơn tổng phễu. Sự khác biệt giữa nhóm là quan sát, chưa chứng minh nguyên nhân.', '']
    if weak:
        body += [f"Độ nhạy timestamp: strict có **{data['counts'][-1]:,}** phiên hoàn tất; weak có **{weak['counts'][-1]:,}**. Đây là hai chính sách xử lý đồng thời, không xác định được thứ tự thật.", '']
    body += [f'Chế độ: `{mode}`. BigQuery job ID: `{job_id or "không có"}`. Công cụ chỉ kiểm tra tính nhất quán CSV, không xác minh job từ xa.',
             'Phễu là cấp phiên và có thể gồm nhiều sản phẩm; purchase event khác giao dịch đã xác minh. Dataset mẫu đã được làm nhiễu.', '', '![Phễu](funnel.svg)', '']
    text='\n'.join(body)
    (output_dir/'bao_cao.md').write_text(text,encoding='utf-8')
    (output_dir/'funnel.svg').write_text(funnel_svg(data,watermark),encoding='utf-8')
    meta={'mode':mode,'job_id_user_supplied':job_id,'remote_job_verified':False,'eligible_sessions':data['eligible'],'funnel_counts':data['counts'],'weak_counts':weak['counts'] if weak else None}
    (output_dir/'report_manifest.json').write_text(json.dumps(meta,indent=2,ensure_ascii=False),encoding='utf-8')
    return meta


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',type=Path,required=True,help='Folder containing 07, 08 and 08b CSV result sets')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--mode',choices=['fixture','source'],required=True)
    p.add_argument('--weak',type=Path,help='Optional weak-order results for the same run/cohort')
    p.add_argument('--job-id',help='Required in source mode; recorded but not remotely verified')
    a=p.parse_args()
    try:
        print(json.dumps(build(a.input,a.output,a.mode,a.weak,a.job_id),ensure_ascii=False,indent=2))
    except (ValueError,OSError) as e:
        p.exit(2, f'Không tạo báo cáo: {e}\n')


if __name__ == '__main__':
    main()
