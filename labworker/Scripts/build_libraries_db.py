#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Build SQLite database from sgRNA设计-文库版.html and shRNA设计-文库版.html
Stores 123,411 human sgRNA + 81,522 human shRNA + curated mouse libraries.
Outputs to Sources/CloneStudioCore/Resources/Libraries.sqlite
"""

import os
import re
import sqlite3
import time

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DB = os.path.join(BASE_DIR, "Sources/CloneStudioCore/Resources/Libraries.sqlite")

os.makedirs(os.path.dirname(OUT_DB), exist_ok=True)
if os.path.exists(OUT_DB):
    os.remove(OUT_DB)

conn = sqlite3.connect(OUT_DB)
cur = conn.cursor()

# Create tables
cur.execute("""
CREATE TABLE sgrna (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    gene TEXT NOT NULL,
    gene_upper TEXT NOT NULL,
    seq TEXT NOT NULL,
    species TEXT NOT NULL -- 'human' or 'mouse'
);
""")
cur.execute("CREATE INDEX idx_sgrna_spec_gene ON sgrna(species, gene_upper);")

cur.execute("""
CREATE TABLE shrna (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    gene TEXT NOT NULL,
    gene_upper TEXT NOT NULL,
    seq TEXT NOT NULL,
    species TEXT NOT NULL -- 'human' or 'mouse'
);
""")
cur.execute("CREATE INDEX idx_shrna_spec_gene ON shrna(species, gene_upper);")

# 1. Parse Human sgRNA
print("📖 Parsing Human sgRNA library...")
t0 = time.time()
sg_html_path = os.path.join(BASE_DIR, "sgRNA设计-文库版.html")
with open(sg_html_path, "r", encoding="utf-8") as f:
    c = f.read()

sg_matches = re.findall(r'\{\s*gene\s*:\s*[\'"]([^\'"]+)[\'"],\s*seq\s*:\s*[\'"]([^\'"]+)[\'"]\s*\}', c)
human_sg_rows = [(m[0].strip(), m[0].strip().upper(), m[1].strip().upper(), "human") for m in sg_matches]
cur.executemany("INSERT INTO sgrna (gene, gene_upper, seq, species) VALUES (?, ?, ?, ?)", human_sg_rows)
print(f"   ✅ Human sgRNA inserted: {len(human_sg_rows)} rows in {time.time()-t0:.2f}s")

# 2. Parse Human shRNA
print("📖 Parsing Human shRNA library...")
t1 = time.time()
sh_html_path = os.path.join(BASE_DIR, "shRNA设计-文库版.html")
with open(sh_html_path, "r", encoding="utf-8") as f:
    c2 = f.read()

raw_blocks = c2.split('{')
human_sh_rows = []
for b in raw_blocks:
    g_m = re.search(r'(?:gene|name)\s*[\'"]?\s*:\s*[\'"]?([^\'",}\s]+)[\'"]?', b)
    s_m = re.search(r'(?:seq|sequence)\s*[\'"]?\s*:\s*[\'"]?([^\'",}\s]+)[\'"]?', b)
    if g_m and s_m:
        g = g_m.group(1).strip()
        s = s_m.group(1).strip()
        clean_s = re.sub(r'[^ATCGatcg]', '', s)
        if 15 <= len(clean_s) <= 35:
            human_sh_rows.append((g, g.upper(), clean_s.upper(), "human"))

cur.executemany("INSERT INTO shrna (gene, gene_upper, seq, species) VALUES (?, ?, ?, ?)", human_sh_rows)
print(f"   ✅ Human shRNA inserted: {len(human_sh_rows)} rows in {time.time()-t1:.2f}s")

# 3. Add Curated Mouse Library Seeds (经典小鼠基因 Brie / TRC 靶点)
print("🐭 Populating curated Mouse sgRNA & shRNA seed library...")
mouse_sg_seed = [
    # Trp53 (p53)
    ("Trp53", "CGTCATGTGCTGTGACTTCT"),
    ("Trp53", "CCCGAGTATCTGGAAGACAG"),
    ("Trp53", "GACATCCTGCTCCCCGAGTA"),
    ("Trp53", "CATCCTGCTCCCCGAGTATG"),
    # Myc
    ("Myc", "CCAGGAGGAACAAGAAGATG"),
    ("Myc", "GACAGCCCCTGCGACCGACC"),
    ("Myc", "GCAGAGCGACGCGGCGGCGC"),
    # Egfr
    ("Egfr", "CGTTCATGCAGCAGCATCGC"),
    ("Egfr", "CAGAACCTTGAAACACATAG"),
    ("Egfr", "GATGACAGTGTCATACTCAG"),
    # Kras
    ("Kras", "GACTGAGTATAAACTTGTGG"),
    ("Kras", "GTAGTTGGAGCTGGTGGCGT"),
    ("Kras", "CTCGACACAGCAGGTCAAGA"),
    # Akt1
    ("Akt1", "CAGCCCTGAAACCGCTCCTG"),
    ("Akt1", "GACCGTGTGACCATGAACGA"),
    ("Akt1", "CGTGTGACCATGAACGAGTT"),
    # Pten
    ("Pten", "GAGATCGTTAGCAGAAACAA"),
    ("Pten", "GTTCACGTCCTTGGTTCGTT"),
    ("Pten", "CGGCTCTCCGAGTAGCATAG"),
    # Gapdh
    ("Gapdh", "CGACTTCAACAGCAACTCCC"),
    ("Gapdh", "CACCACCCTGTTGCTGTAGC"),
    # Actb
    ("Actb", "CGTGAAAAGATGACCCAGAT"),
    ("Actb", "GATCTGGCACCACACCTTCT")
]
cur.executemany("INSERT INTO sgrna (gene, gene_upper, seq, species) VALUES (?, ?, ?, ?)", 
                 [(g, g.upper(), s, "mouse") for g, s in mouse_sg_seed])

mouse_sh_seed = [
    # Trp53
    ("Trp53", "CACGTACTCTCCTCCCCTCAAT"),
    ("Trp53", "CCTTGCCCTCAACAAGATGTTT"),
    ("Trp53", "GAAACACTACTTCCTCCGAAGA"),
    # Myc
    ("Myc", "CAGCAGCGACTCTGAAGAAGAG"),
    ("Myc", "GAATACATCCTGTCCGTCCAAG"),
    # Egfr
    ("Egfr", "GCAACATCGTCCGGAACAATAT"),
    ("Egfr", "GAAGTGAGACCAGTGAATATGT"),
    # Kras
    ("Kras", "CCAGTAGACATCAGTACAAAGT"),
    ("Kras", "GGAGATGTTCCTTTGATAGTGT"),
    # Akt1
    ("Akt1", "GACATCAAGATGATCAAGTTCT"),
    ("Akt1", "CTATGGCGCTGAGATTGTGTCA"),
    # Pten
    ("Pten", "GCAACATTTCTAAAGTTACCTA"),
    ("Pten", "GAAGTTTGCCTATGATACAAAT"),
    # Gapdh
    ("Gapdh", "GCAAATTCAACGGCACAGTCAA"),
    # Actb
    ("Actb", "CAAGAGAGGTATCCTGACCCTG")
]
cur.executemany("INSERT INTO shrna (gene, gene_upper, seq, species) VALUES (?, ?, ?, ?)",
                 [(g, g.upper(), s, "mouse") for g, s in mouse_sh_seed])

conn.commit()
conn.close()

db_size = os.path.getsize(OUT_DB) / (1024 * 1024)
print(f"🎉 Libraries database built successfully at: {OUT_DB} ({db_size:.2f} MB)")
