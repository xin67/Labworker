#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CHOPCHOP 在线靶点与全基因组脱靶预测后台高速异步调用脚本
优化特性：
1. 移除冗余服务端文件生成参数 (-J, -BED, -GenBank, -repairPredictions)，仅请求核心 Bowtie 错配比对与 Doench 2016 效率分
2. 使用单条 HTTPS Keep-Alive 持久连接，避免重复 TCP/TLS 握手
3. 自适应高频轮询 (0.5s -> 0.8s -> 1.0s -> 1.2s)，算完即刻返回
4. 支持双层持久化缓存与 --force-refresh 强制刷新
"""

import sys
import os
import argparse
import json
import time
import ssl
import http.client
import urllib.request
import urllib.error


def eprint(*args, **kwargs):
    """输出状态日志到 stderr，供 Swift Process 实时捕获进度"""
    print(*args, file=sys.stderr, flush=True)


def get_cache_paths(clean_gene, genome, target_region, custom_cache_dir=None):
    key = f"{clean_gene.upper()}_{genome.lower()}_{target_region}.json"
    paths = []
    if custom_cache_dir:
        os.makedirs(custom_cache_dir, exist_ok=True)
        paths.append(os.path.join(custom_cache_dir, key))

    app_support_dir = os.path.expanduser("~/Library/Application Support/CloneStudio/chopchop_cache")
    try:
        os.makedirs(app_support_dir, exist_ok=True)
        paths.append(os.path.join(app_support_dir, key))
    except Exception:
        pass

    home_cache_dir = os.path.expanduser("~/.cache/chopchop_cache")
    try:
        os.makedirs(home_cache_dir, exist_ok=True)
        paths.append(os.path.join(home_cache_dir, key))
    except Exception:
        pass

    return paths


def query_chopchop(gene, genome="hg38", target_region="CODING", timeout=60, cache_dir=None, force_refresh=False):
    clean_gene = gene.strip()
    if not clean_gene:
        return {"status": "error", "message": "目标基因名称不能为空"}

    cache_paths = get_cache_paths(clean_gene, genome, target_region, cache_dir)

    # 1. 检查本地缓存（除非用户点击了强制刷新）
    if not force_refresh:
        for cpath in cache_paths:
            if os.path.exists(cpath):
                try:
                    with open(cpath, "r", encoding="utf-8") as f:
                        cached_data = json.load(f)
                        if cached_data.get("targets"):
                            cached_data["cached"] = True
                            eprint("PROGRESS: 命中本地历史缓存，极速载入中...")
                            return cached_data
                except Exception:
                    continue

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    eprint(f"PROGRESS: 正在向 CHOPCHOP 提交「{clean_gene}」({genome}) 极速检索请求...")

    # 仅保留核心计算参数，剔除耗时的 -J / -BED / -GenBank / -repairPredictions
    payload = {
        "opts": [
            "-G", genome,
            "-filterGCmin", "10",
            "-filterGCmax", "90",
            "-t", target_region,
            "-n", "",
            "-R", "4",
            "-T", "1",
            "-g", "20",
            "-scoringMethod", "DOENCH_2016",
            "-f", "NN",
            "-v", "3",
            "-M", "NGG"
        ],
        "fastaInput": "",
        "geneInput": clean_gene,
        "isIsoform": False,
        "forSelect": "knock-out"
    }

    headers = {
        "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "X-Requested-With": "XMLHttpRequest",
        "Origin": "https://chopchop.cbu.uib.no",
        "Referer": "https://chopchop.cbu.uib.no/",
        "Connection": "keep-alive"
    }

    conn = None
    job_id = None
    try:
        conn = http.client.HTTPSConnection("chopchop.cbu.uib.no", timeout=20, context=ctx)
        conn.request("POST", "/", body=json.dumps(payload).encode("utf-8"), headers=headers)
        resp = conn.getresponse()
        raw_body = resp.read().decode("utf-8")
        if resp.status == 200:
            submit_res = json.loads(raw_body)
            job_id = submit_res.get("jobId")
        else:
            return {"status": "error", "message": f"CHOPCHOP 服务器返回状态码 {resp.status}"}
    except Exception as e:
        return {"status": "error", "message": f"连接 CHOPCHOP 服务器失败: {str(e)}"}

    if not job_id:
        return {"status": "error", "message": "未能获取 CHOPCHOP 任务排队 ID，请检查基因名是否正确"}

    eprint(f"PROGRESS: 任务已提交 (ID: {job_id[:8]}...)，正在高速轮询全基因组比对结果...")

    tsv_path = f"/results/{job_id}/results.tsv"
    start_time = time.time()
    tsv_content = None
    poll_idx = 0
    poll_intervals = [0.45, 0.65, 0.85, 1.0, 1.2]

    while time.time() - start_time < timeout:
        wait_sec = poll_intervals[min(poll_idx, len(poll_intervals) - 1)]
        time.sleep(wait_sec)
        poll_idx += 1
        elapsed = time.time() - start_time
        eprint(f"PROGRESS: 全基因组错配比对中... ({elapsed:.1f}s)")

        try:
            if conn is None:
                conn = http.client.HTTPSConnection("chopchop.cbu.uib.no", timeout=10, context=ctx)
            conn.request("GET", tsv_path, headers={
                "User-Agent": headers["User-Agent"],
                "Connection": "keep-alive"
            })
            tsv_resp = conn.getresponse()
            body_bytes = tsv_resp.read()
            if tsv_resp.status == 200 and body_bytes:
                tsv_content = body_bytes.decode("utf-8")
                break
            elif tsv_resp.status == 404:
                continue
        except Exception:
            try:
                if conn:
                    conn.close()
            except Exception:
                pass
            conn = None
            continue

    try:
        if conn:
            conn.close()
    except Exception:
        pass

    if not tsv_content:
        return {"status": "error", "message": f"等待 CHOPCHOP 运算结果超时 ({timeout} 秒)，服务器可能繁忙，请稍后重试"}

    eprint("PROGRESS: 计算完毕，正在解析全基因组脱靶位点与综合评分...")

    lines = tsv_content.strip().splitlines()
    if len(lines) <= 1:
        return {"status": "success", "jobId": job_id, "gene": clean_gene, "genome": genome, "count": 0, "targets": []}

    targets = []
    # Rank	Target sequence	Genomic location	Strand	GC content (%)	Self-complementarity	MM0	MM1	MM2	MM3	Efficiency
    for line in lines[1:]:
        cols = line.split("\t")
        if len(cols) < 11:
            continue
        try:
            rank = int(cols[0])
            full_seq = cols[1].strip().upper()
            spacer = full_seq[:20]
            pam = full_seq[20:] if len(full_seq) > 20 else ""
            genomic_loc = cols[2].strip()
            strand = cols[3].strip()
            gc_val = float(cols[4])
            self_comp = int(cols[5])
            mm0 = int(cols[6])
            mm1 = int(cols[7])
            mm2 = int(cols[8])
            mm3 = int(cols[9])
            efficiency = float(cols[10])

            targets.append({
                "rank": rank,
                "targetSequence": full_seq,
                "spacer": spacer,
                "pam": pam,
                "genomicLocation": genomic_loc,
                "strand": strand,
                "gcContent": gc_val,
                "selfComplementarity": self_comp,
                "mm0": mm0,
                "mm1": mm1,
                "mm2": mm2,
                "mm3": mm3,
                "efficiency": efficiency
            })
        except Exception:
            continue

    result_data = {
        "status": "success",
        "jobId": job_id,
        "gene": clean_gene,
        "genome": genome,
        "count": len(targets),
        "cached": False,
        "targets": targets
    }

    # 写入全部缓存路径
    for cpath in cache_paths:
        try:
            with open(cpath, "w", encoding="utf-8") as f:
                json.dump(result_data, f, ensure_ascii=False)
        except Exception:
            continue

    return result_data


def main():
    parser = argparse.ArgumentParser(description="Query CHOPCHOP online CRISPR API")
    parser.add_argument("--gene", required=True, help="Target gene symbol (e.g. TP53)")
    parser.add_argument("--genome", default="hg38", help="Genome assembly (e.g. hg38 or mm39)")
    parser.add_argument("--target", default="CODING", help="Target region (CODING, WHOLE, etc.)")
    parser.add_argument("--timeout", type=int, default=50, help="Timeout in seconds")
    parser.add_argument("--cache-dir", default=None, help="Cache directory")
    parser.add_argument("--force-refresh", action="store_true", help="Ignore local cache and re-query CHOPCHOP")

    args = parser.parse_args()

    res = query_chopchop(
        gene=args.gene,
        genome=args.genome,
        target_region=args.target,
        timeout=args.timeout,
        cache_dir=args.cache_dir,
        force_refresh=args.force_refresh
    )

    print(json.dumps(res, ensure_ascii=False))


if __name__ == "__main__":
    main()
