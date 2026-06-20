#!/usr/bin/env python3
# LazyVPS Combined Report Merger
# 合并 VPS 端回程测试与本地端去程测试结果
import argparse, csv, pathlib, datetime

def read_csv(path):
    try:
        with open(path, encoding='utf-8-sig') as f:
            return list(csv.DictReader(f))
    except Exception:
        return []

def read_kv(path):
    rows=read_csv(path)
    out={}
    for r in rows:
        k=r.get('Item') or r.get('item')
        v=r.get('Value') or r.get('value')
        if k: out[k]=v
    return out

def main():
    ap=argparse.ArgumentParser(description='Merge LazyVPS VPS-side and Client-side reports')
    ap.add_argument('--server-dir', required=True, help='VPS端测试输出目录，例如 cn3_test_20260620_123456')
    ap.add_argument('--client-dir', required=True, help='本地端测试输出目录，例如 cn3_client_test_20260620_123456')
    ap.add_argument('--out', default='combined_lazyvps_report.md')
    args=ap.parse_args()

    server=pathlib.Path(args.server_dir)
    client=pathlib.Path(args.client_dir)
    s_over=read_csv(server/'cn3_overview.csv')
    s_route=read_csv(server/'route_backbone_summary.csv')
    c_sum=read_kv(client/'client_summary.csv')
    c_tcp=read_csv(client/'tcp_ports.csv')
    c_proxy=read_csv(client/'proxy_experience.csv')

    s_over=sorted(s_over, key=lambda r: float(r.get('综合评分') or 0), reverse=True)
    best=s_over[0] if s_over else {}

    md=[]
    md.append('# LazyVPS 综合闭环测试报告')
    md.append('')
    md.append(f'- 生成时间：{datetime.datetime.now():%F %T}')
    md.append(f'- VPS 端目录：`{server}`')
    md.append(f'- 本地端目录：`{client}`')
    md.append('')
    md.append('## 1. 闭环结论')
    md.append('')
    md.append(f'- VPS 回程优先方向：**{best.get("运营商","NA")}**，综合评分 **{best.get("综合评分","NA")}**，评级 **{best.get("评级","NA")}**。')
    md.append(f'- 本地去程目标 VPS：**{c_sum.get("VpsHost","NA")}**。')
    md.append(f'- 本地去程 Ping：**{c_sum.get("PingAvgMs","NA")} ms**，丢包 **{c_sum.get("PingLossPercent","NA")}%**。')
    md.append(f'- 本地端评分：**{c_sum.get("Score","NA")} / {c_sum.get("Grade","NA")}**。')
    md.append('')
    md.append('> 综合判断建议：VPS 端看回程与骨干，本地端看去程与实际连通，代理体感看真实业务，两端结果一起看才是完整闭环。')
    md.append('')
    md.append('## 2. VPS 端三网回程总表')
    md.append('')
    if s_over:
        fields=['排名','运营商','综合评分','评级','平均Pingms','平均Ping丢包%','TCP成功率%','平均下载Mbps','平均上传Mbps','建议']
        md.append('| ' + ' | '.join(fields) + ' |')
        md.append('| ' + ' | '.join(['---']*len(fields)) + ' |')
        for r in s_over:
            md.append('| ' + ' | '.join(str(r.get(f,'')) for f in fields) + ' |')
    else:
        md.append('_未找到 VPS 端总表。_')
    md.append('')
    md.append('## 3. VPS 端回程骨干')
    md.append('')
    if s_route:
        md.append('| 运营商 | 回程骨干识别 | 关键特征 |')
        md.append('|---|---|---|')
        for r in s_route:
            md.append(f"| {r.get('运营商','')} | {r.get('回程骨干识别','')} | {r.get('关键特征','')} |")
    else:
        md.append('_未找到回程骨干摘要。_')
    md.append('')
    md.append('## 4. 本地端 TCP 端口')
    md.append('')
    if c_tcp:
        md.append('| Port | Status | LatencyMs |')
        md.append('|---|---|---|')
        for r in c_tcp:
            md.append(f"| {r.get('Port','')} | {r.get('Status','')} | {r.get('LatencyMs','')} |")
    else:
        md.append('_未找到 TCP 端口结果。_')
    md.append('')
    md.append('## 5. 本地端代理体感')
    md.append('')
    if c_proxy:
        md.append('| Name | Status | HttpCode | LatencyMs |')
        md.append('|---|---|---|---|')
        for r in c_proxy:
            md.append(f"| {r.get('Name','')} | {r.get('Status','')} | {r.get('HttpCode','')} | {r.get('LatencyMs','')} |")
    else:
        md.append('_未设置代理或未找到代理体感结果。_')
    md.append('')
    pathlib.Path(args.out).write_text('\n'.join(md), encoding='utf-8')
    print(f'已输出：{args.out}')

if __name__ == '__main__':
    main()
