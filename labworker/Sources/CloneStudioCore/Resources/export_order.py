#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Order Form Generator for Labworker / CloneStudio macOS (Stdlib Only)
Handles:
1. 擎科引物合成订购表.xlsx
2. 擎科测序订购表专属电子订单.xlsx
3. 生工DNA测序订购表.xlsx
4. DNA测序订购表_V9(1).xlsx (生工通用 V9 版)
5. International & Gene Synthesis Bulk Orders (.xlsx / .csv):
   - idt_bulk (IDT Bulk Input)
   - twist_bulk (Twist Bioscience)
   - genscript_bulk (GenScript GenSmart)
   - eurofins_bulk (Eurofins Genomics)
   - bgi_bulk (BGI 华大基因)
   - custom_json (User-defined JSON column mapping)
Preserves original template formatting, styles, borders, and formulas for vendor .xlsx workbooks.
"""

import csv
import datetime
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
ET.register_namespace('', NS)

DEFAULT_UNIFIED_ADDRESS = '生命科学园区实验楼A座'
IDT_DISALLOWED_CHARS = set("<>'/\\&\",~")

def set_cell_inline_str(row_elem, cells_map, col, row_idx, val):
    cell_ref = f'{col}{row_idx}'
    c = cells_map.get(cell_ref)
    if c is None:
        c = ET.SubElement(row_elem, f'{{{NS}}}c', {'r': cell_ref})
        cells_map[cell_ref] = c
    c.attrib['t'] = 'inlineStr'
    for child in list(c):
        if child.tag.endswith('}v') or child.tag.endswith('}is'):
            c.remove(child)
    is_elem = ET.SubElement(c, f'{{{NS}}}is')
    t_elem = ET.SubElement(is_elem, f'{{{NS}}}t')
    t_elem.text = str(val) if val is not None else ''

# 1. 擎科引物合成订购表
def export_tsingke_primer(template_path, output_path, primers_data, profile):
    with tempfile.TemporaryDirectory() as td:
        with zipfile.ZipFile(template_path, 'r') as zin:
            zin.extractall(td)
        
        sheet_path = os.path.join(td, 'xl', 'worksheets', 'sheet1.xml')
        tree = ET.parse(sheet_path)
        root = tree.getroot()
        sheetData = root.find(f'{{{NS}}}sheetData')
        if sheetData is None:
            raise ValueError("Invalid spreadsheet: sheetData not found")
        
        rows_by_idx = {}
        for r in sheetData.findall(f'{{{NS}}}row'):
            r_idx = int(r.attrib.get('r', '0'))
            rows_by_idx[r_idx] = r
            
        # 表头信息更新
        def fill_header_cell(row_num, col_letter, val):
            row = rows_by_idx.get(row_num)
            if row is not None:
                c_map = {c.attrib.get('r'): c for c in row.findall(f'{{{NS}}}c')}
                set_cell_inline_str(row, c_map, col_letter, row_num, val)
                
        if profile.get('customerName'):
            fill_header_cell(4, 'B', profile['customerName'])
        if profile.get('piName'):
            fill_header_cell(5, 'B', profile['piName'])
        if profile.get('organization'):
            fill_header_cell(6, 'B', profile['organization'])
            fill_header_cell(7, 'B', profile['organization'])
        addr = profile.get('address') or DEFAULT_UNIFIED_ADDRESS
        fill_header_cell(8, 'B', addr)
        if profile.get('phone'):
            fill_header_cell(10, 'B', profile['phone'])
        if profile.get('email'):
            fill_header_cell(11, 'B', profile['email'])
            
        start_row = 13
        for i, item in enumerate(primers_data):
            row_idx = start_row + i
            seq = item.get('fullSequence', '').strip().upper()
            name = item.get('name', f'Primer-{i+1}')
            purity = item.get('purity', profile.get('defaultPurity', 'PAGE'))
            od = str(item.get('od', profile.get('defaultOD', 2.0)))
            tubes = str(item.get('tubes', 1))
            purpose = item.get('targetPurpose', '片段扩增')
            notes = item.get('notes', '')
            base_count = str(len(seq))
            
            row_elem = rows_by_idx.get(row_idx)
            if row_elem is None:
                row_elem = ET.SubElement(sheetData, f'{{{NS}}}row', {'r': str(row_idx)})
                rows_by_idx[row_idx] = row_elem
                
            cells_map = {c.attrib.get('r'): c for c in row_elem.findall(f'{{{NS}}}c')}
            
            set_cell_inline_str(row_elem, cells_map, 'A', row_idx, str(i + 1))
            set_cell_inline_str(row_elem, cells_map, 'B', row_idx, name)
            set_cell_inline_str(row_elem, cells_map, 'C', row_idx, seq)
            set_cell_inline_str(row_elem, cells_map, 'D', row_idx, base_count)
            set_cell_inline_str(row_elem, cells_map, 'E', row_idx, purity)
            set_cell_inline_str(row_elem, cells_map, 'F', row_idx, od)
            set_cell_inline_str(row_elem, cells_map, 'G', row_idx, tubes)
            set_cell_inline_str(row_elem, cells_map, 'H', row_idx, purpose)
            set_cell_inline_str(row_elem, cells_map, 'I', row_idx, notes)
            
        tree.write(sheet_path, encoding='utf-8', xml_declaration=True)
        
        with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as zout:
            for root_dir, dirs, files in os.walk(td):
                for file in files:
                    full_p = os.path.join(root_dir, file)
                    rel_p = os.path.relpath(full_p, td)
                    zout.write(full_p, rel_p)

# 2. 擎科测序订购表专属电子订单
def export_tsingke_seq(template_path, output_path, samples_data, profile):
    with tempfile.TemporaryDirectory() as td:
        with zipfile.ZipFile(template_path, 'r') as zin:
            zin.extractall(td)
        
        sheet_path = os.path.join(td, 'xl', 'worksheets', 'sheet1.xml')
        tree = ET.parse(sheet_path)
        root = tree.getroot()
        sheetData = root.find(f'{{{NS}}}sheetData')
        if sheetData is None:
            raise ValueError("Invalid spreadsheet: sheetData not found")
        
        rows_by_idx = {}
        for r in sheetData.findall(f'{{{NS}}}row'):
            r_idx = int(r.attrib.get('r', '0'))
            rows_by_idx[r_idx] = r
            
        # 更新表头订购人信息 (Row 6 & 7)
        row6 = rows_by_idx.get(6)
        if row6 is not None:
            c_map6 = {c.attrib.get('r'): c for c in row6.findall(f'{{{NS}}}c')}
            if profile.get('customerName'):
                set_cell_inline_str(row6, c_map6, 'B', 6, profile['customerName'])
            if profile.get('piName'):
                set_cell_inline_str(row6, c_map6, 'D', 6, profile['piName'])
            if profile.get('email'):
                set_cell_inline_str(row6, c_map6, 'F', 6, profile['email'])
            if profile.get('phone'):
                set_cell_inline_str(row6, c_map6, 'M', 6, profile['phone'])
                
        row7 = rows_by_idx.get(7)
        if row7 is not None:
            c_map7 = {c.attrib.get('r'): c for c in row7.findall(f'{{{NS}}}c')}
            if profile.get('organization'):
                set_cell_inline_str(row7, c_map7, 'B', 7, profile['organization'])
            addr = profile.get('address') or DEFAULT_UNIFIED_ADDRESS
            set_cell_inline_str(row7, c_map7, 'F', 7, addr)
                
        start_row = 13
        for i, item in enumerate(samples_data):
            row_idx = start_row + i
            sample_name = item.get('sampleName', f'Sample-{i+1}')
            sample_type = item.get('sampleType', 'B、质粒')
            if not sample_type.startswith(('A、', 'B、', 'D、', 'E、', 'F、')):
                sample_type = 'B、质粒' if '质粒' in sample_type else ('A、菌液' if '菌' in sample_type else 'B、质粒')
                
            frag_len = str(item.get('fragmentLength', '1000'))
            resistance = item.get('resistance', 'Amp')
            vector_name = item.get('vectorName', 'pCE-Entry')
            primer_cat = item.get('primerCategory', 'A、通用引物')
            primer1 = item.get('primerName', 'T7')
            primer2 = item.get('primerName2', '')
            conc = str(item.get('primerConc', '10'))
            req = item.get('requirement', 'D、测通')
            if not req.startswith(('A、', 'B、', 'C、', 'D、')):
                req = 'D、测通'
            charact = item.get('characteristics', 'A、正常')
            return_req = item.get('returnRequirement', 'C、无需返还质粒')
            notes = item.get('notes', '')
            
            row_elem = rows_by_idx.get(row_idx)
            if row_elem is None:
                row_elem = ET.SubElement(sheetData, f'{{{NS}}}row', {'r': str(row_idx)})
                rows_by_idx[row_idx] = row_elem
                
            cells_map = {c.attrib.get('r'): c for c in row_elem.findall(f'{{{NS}}}c')}
            
            set_cell_inline_str(row_elem, cells_map, 'A', row_idx, sample_name)
            set_cell_inline_str(row_elem, cells_map, 'B', row_idx, sample_type)
            set_cell_inline_str(row_elem, cells_map, 'C', row_idx, frag_len)
            set_cell_inline_str(row_elem, cells_map, 'D', row_idx, resistance)
            set_cell_inline_str(row_elem, cells_map, 'E', row_idx, vector_name)
            set_cell_inline_str(row_elem, cells_map, 'F', row_idx, primer_cat)
            set_cell_inline_str(row_elem, cells_map, 'G', row_idx, primer1)
            set_cell_inline_str(row_elem, cells_map, 'H', row_idx, primer2)
            set_cell_inline_str(row_elem, cells_map, 'L', row_idx, conc)
            set_cell_inline_str(row_elem, cells_map, 'M', row_idx, req)
            set_cell_inline_str(row_elem, cells_map, 'N', row_idx, charact)
            set_cell_inline_str(row_elem, cells_map, 'O', row_idx, return_req)
            set_cell_inline_str(row_elem, cells_map, 'P', row_idx, notes)
            
        tree.write(sheet_path, encoding='utf-8', xml_declaration=True)
        
        with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as zout:
            for root_dir, dirs, files in os.walk(td):
                for file in files:
                    full_p = os.path.join(root_dir, file)
                    rel_p = os.path.relpath(full_p, td)
                    zout.write(full_p, rel_p)

# 3. 生工 DNA 测序订购表 (专属版)
def export_sangon_seq(template_path, output_path, samples_data, profile):
    with tempfile.TemporaryDirectory() as td:
        with zipfile.ZipFile(template_path, 'r') as zin:
            zin.extractall(td)
        
        sheet_path = os.path.join(td, 'xl', 'worksheets', 'sheet1.xml')
        tree = ET.parse(sheet_path)
        root = tree.getroot()
        sheetData = root.find(f'{{{NS}}}sheetData')
        if sheetData is None:
            raise ValueError("Invalid spreadsheet: sheetData not found")
        
        rows_by_idx = {}
        for r in sheetData.findall(f'{{{NS}}}row'):
            r_idx = int(r.attrib.get('r', '0'))
            rows_by_idx[r_idx] = r
            
        # 表头信息更新
        def fill_header_cell(row_num, col_letter, val):
            row = rows_by_idx.get(row_num)
            if row is not None:
                c_map = {c.attrib.get('r'): c for c in row.findall(f'{{{NS}}}c')}
                set_cell_inline_str(row, c_map, col_letter, row_num, val)
                
        if profile.get('customerName'):
            fill_header_cell(4, 'B', profile['customerName'])
        if profile.get('phone'):
            fill_header_cell(5, 'B', profile['phone'])
        if profile.get('email'):
            fill_header_cell(6, 'B', profile['email'])
        if profile.get('piName'):
            fill_header_cell(7, 'B', profile['piName'])
        if profile.get('organization'):
            fill_header_cell(8, 'B', profile['organization'])
            fill_header_cell(9, 'B', profile['organization'])
        addr = profile.get('address') or DEFAULT_UNIFIED_ADDRESS
        fill_header_cell(12, 'B', addr)
            
        start_row = 18
        for i, item in enumerate(samples_data):
            row_idx = start_row + i
            sample_name = item.get('sampleName', f'Sample-{i+1}')
            sample_type = item.get('sampleType', '质粒')
            resistance = item.get('resistance', 'Amp')
            vector_name = item.get('vectorName', 'pCE-Entry')
            frag_len = str(item.get('fragmentLength', '1000'))
            primer_name = item.get('primerName', 'T7')
            primer_type = item.get('primerType', '通用')
            req = item.get('requirement', '单向测通')
            notes = item.get('notes', '')
            
            row_elem = rows_by_idx.get(row_idx)
            if row_elem is None:
                row_elem = ET.SubElement(sheetData, f'{{{NS}}}row', {'r': str(row_idx)})
                rows_by_idx[row_idx] = row_elem
                
            cells_map = {c.attrib.get('r'): c for c in row_elem.findall(f'{{{NS}}}c')}
            
            set_cell_inline_str(row_elem, cells_map, 'A', row_idx, sample_name)
            set_cell_inline_str(row_elem, cells_map, 'B', row_idx, sample_type)
            set_cell_inline_str(row_elem, cells_map, 'C', row_idx, resistance)
            set_cell_inline_str(row_elem, cells_map, 'D', row_idx, vector_name)
            set_cell_inline_str(row_elem, cells_map, 'E', row_idx, frag_len)
            set_cell_inline_str(row_elem, cells_map, 'F', row_idx, primer_name)
            set_cell_inline_str(row_elem, cells_map, 'G', row_idx, primer_type)
            set_cell_inline_str(row_elem, cells_map, 'H', row_idx, req)
            set_cell_inline_str(row_elem, cells_map, 'I', row_idx, notes)

        tree.write(sheet_path, encoding='utf-8', xml_declaration=True)
        
        with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as zout:
            for root_dir, dirs, files in os.walk(td):
                for file in files:
                    full_p = os.path.join(root_dir, file)
                    rel_p = os.path.relpath(full_p, td)
                    zout.write(full_p, rel_p)

# 4. 生工 DNA 测序订购表 (官方通用 V9 版)
def export_sangon_v9_seq(template_path, output_path, samples_data, profile):
    with tempfile.TemporaryDirectory() as td:
        with zipfile.ZipFile(template_path, 'r') as zin:
            zin.extractall(td)
        
        sheet_path = os.path.join(td, 'xl', 'worksheets', 'sheet1.xml')
        tree = ET.parse(sheet_path)
        root = tree.getroot()
        sheetData = root.find(f'{{{NS}}}sheetData')
        if sheetData is None:
            raise ValueError("Invalid spreadsheet: sheetData not found")
        
        rows_by_idx = {}
        for r in sheetData.findall(f'{{{NS}}}row'):
            r_idx = int(r.attrib.get('r', '0'))
            rows_by_idx[r_idx] = r
            
        def fill_header_cell(row_num, col_letter, val):
            row = rows_by_idx.get(row_num)
            if row is not None:
                c_map = {c.attrib.get('r'): c for c in row.findall(f'{{{NS}}}c')}
                set_cell_inline_str(row, c_map, col_letter, row_num, val)
                
        if profile.get('customerName'):
            fill_header_cell(4, 'B', profile['customerName'])
        if profile.get('phone'):
            fill_header_cell(5, 'B', profile['phone'])
        if profile.get('email'):
            fill_header_cell(6, 'B', profile['email'])
        if profile.get('piName'):
            fill_header_cell(7, 'B', profile['piName'])
        if profile.get('organization'):
            fill_header_cell(8, 'B', profile['organization'])
            fill_header_cell(9, 'B', profile['organization']) # 发票抬头
            
        addr = profile.get('address') or DEFAULT_UNIFIED_ADDRESS
        fill_header_cell(12, 'B', addr)
            
        start_row = 19
        for i, item in enumerate(samples_data):
            row_idx = start_row + i
            sample_name = item.get('sampleName', f'Sample-{i+1}')
            sample_type = item.get('sampleType', '质粒')
            resistance = item.get('resistance', 'Amp')
            vector_name = item.get('vectorName', 'pCE-Entry')
            frag_len = str(item.get('fragmentLength', '1000'))
            primer_name = item.get('primerName', 'T7')
            primer_type = item.get('primerType', '通用')
            req = item.get('requirement', '单向测通')
            notes = item.get('notes', '')
            
            row_elem = rows_by_idx.get(row_idx)
            if row_elem is None:
                row_elem = ET.SubElement(sheetData, f'{{{NS}}}row', {'r': str(row_idx)})
                rows_by_idx[row_idx] = row_elem
                
            cells_map = {c.attrib.get('r'): c for c in row_elem.findall(f'{{{NS}}}c')}
            
            set_cell_inline_str(row_elem, cells_map, 'A', row_idx, sample_name)
            set_cell_inline_str(row_elem, cells_map, 'B', row_idx, sample_type)
            set_cell_inline_str(row_elem, cells_map, 'C', row_idx, resistance)
            set_cell_inline_str(row_elem, cells_map, 'D', row_idx, vector_name)
            set_cell_inline_str(row_elem, cells_map, 'E', row_idx, frag_len)
            set_cell_inline_str(row_elem, cells_map, 'F', row_idx, primer_name)
            set_cell_inline_str(row_elem, cells_map, 'G', row_idx, primer_type)
            set_cell_inline_str(row_elem, cells_map, 'H', row_idx, req)
            set_cell_inline_str(row_elem, cells_map, 'I', row_idx, notes)

        tree.write(sheet_path, encoding='utf-8', xml_declaration=True)
        
        with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as zout:
            for root_dir, dirs, files in os.walk(td):
                for file in files:
                    full_p = os.path.join(root_dir, file)
                    rel_p = os.path.relpath(full_p, td)
                    zout.write(full_p, rel_p)

# MARK: - 5. 国际化引物 / 基因合成批量模板 & 自定义 JSON 列映射 (纯标准库 XLSX / CSV)

def _clean_xml_text(val):
    s = str(val) if val is not None else ''
    return re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', s)

def _col_letter(idx_0based):
    n = idx_0based + 1
    out = ''
    while n > 0:
        n, rem = divmod(n - 1, 26)
        out = chr(65 + rem) + out
    return out

def _idt_scale_from_od(od_val):
    try:
        od = float(od_val)
    except Exception:
        od = 2.0
    if od <= 2.0:
        return '25nm'
    if od <= 5.0:
        return '100nm'
    if od <= 10.0:
        return '250nm'
    return '1um'

def _idt_purification(purity):
    up = str(purity or '').strip().upper()
    if 'PAGE' in up:
        return 'PAGE'
    if 'HPLC' in up:
        return 'HPLC'
    if 'STD' in up or 'DESALT' in up or 'DSL' in up:
        return 'STD'
    return 'STD'

def _sanitize_name(raw, disallowed_chars=None, max_len=0, replacement=''):
    s = str(raw or '')
    if disallowed_chars:
        s = ''.join((replacement if ch in disallowed_chars else ch) for ch in s)
    s = s.strip() or 'Oligo'
    if max_len and max_len > 0 and len(s) > max_len:
        s = s[:max_len]
    return s

def _well96(index_0based):
    rows = 'ABCDEFGH'
    plate_num = (index_0based // 96) + 1
    within = index_0based % 96
    return f'{rows[within // 12]}{(within % 12) + 1}', f'Plate_{plate_num}'

INTERNATIONAL_PRESETS = {
    'idt_bulk': {
        'sheetName': 'IDT Bulk Input',
        'includeHeader': True,
        'delimiter': ',',
        'sanitizeNameChars': "<>'/\\&\",~",
        'maxNameLength': 0,
        'columns': [
            {'header': 'Name', 'field': 'sanitizedNameIDT', 'defaultValue': 'Oligo'},
            {'header': 'Sequence', 'field': 'sequence', 'defaultValue': ''},
            {'header': 'Scale', 'field': 'scaleIDT', 'defaultValue': '25nm'},
            {'header': 'Purification', 'field': 'purificationIDT', 'defaultValue': 'STD'},
        ],
    },
    'twist_bulk': {
        'sheetName': 'Twist Order',
        'includeHeader': True,
        'delimiter': ',',
        'sanitizeNameChars': '',
        'maxNameLength': 0,
        'columns': [
            {'header': 'Sequence Name', 'field': 'name', 'defaultValue': 'Construct'},
            {'header': 'Sequence', 'field': 'sequence', 'defaultValue': ''},
            {'header': 'Well Position', 'field': 'well96', 'defaultValue': 'A1'},
            {'header': 'Plate ID', 'field': 'plateID', 'defaultValue': 'Plate_1'},
            {'header': 'Length (bp)', 'field': 'length', 'defaultValue': '0'},
            {'header': 'Notes', 'field': 'notes', 'defaultValue': ''},
        ],
    },
    'genscript_bulk': {
        'sheetName': 'GenScript Order',
        'includeHeader': True,
        'delimiter': ',',
        'sanitizeNameChars': '',
        'maxNameLength': 0,
        'columns': [
            {'header': 'Gene/Oligo Name', 'field': 'name', 'defaultValue': 'Construct'},
            {'header': "Sequence (5'-3')", 'field': 'sequence', 'defaultValue': ''},
            {'header': 'Length (nt)', 'field': 'length', 'defaultValue': '0'},
            {'header': 'Scale / Quantity', 'field': 'od', 'defaultValue': '2.0 OD'},
            {'header': 'Purification', 'field': 'purificationRaw', 'defaultValue': 'PAGE'},
            {'header': 'Well Position', 'field': 'well96', 'defaultValue': 'A1'},
            {'header': 'Notes', 'field': 'notes', 'defaultValue': ''},
        ],
    },
    'eurofins_bulk': {
        'sheetName': 'Eurofins Plate',
        'includeHeader': True,
        'delimiter': ',',
        'sanitizeNameChars': ' ,.',
        'maxNameLength': 25,
        'columns': [
            {'header': 'Well', 'field': 'well96', 'defaultValue': 'A1'},
            {'header': 'Oligo Name', 'field': 'sanitizedNameEurofins', 'defaultValue': 'Oligo'},
            {'header': 'Sequence', 'field': 'sequence', 'defaultValue': ''},
            {'header': 'Plate Name', 'field': 'plateID', 'defaultValue': 'Plate_1'},
            {'header': "5' Modification", 'field': 'mod5Prime', 'defaultValue': ''},
            {'header': "3' Modification", 'field': 'mod3Prime', 'defaultValue': ''},
            {'header': 'Purification', 'field': 'purificationIDT', 'defaultValue': 'STD'},
            {'header': 'Notes', 'field': 'notes', 'defaultValue': ''},
        ],
    },
    'bgi_bulk': {
        'sheetName': 'BGI Synthesis Order',
        'includeHeader': True,
        'delimiter': ',',
        'sanitizeNameChars': '',
        'maxNameLength': 0,
        'columns': [
            {'header': '引物/基因名称 (Name)', 'field': 'name', 'defaultValue': 'Primer'},
            {'header': "序列 (5'->3')", 'field': 'sequence', 'defaultValue': ''},
            {'header': '碱基数 (bp)', 'field': 'length', 'defaultValue': '0'},
            {'header': '合成规格 (OD)', 'field': 'od', 'defaultValue': '2.0 OD'},
            {'header': '纯化方式 (Purification)', 'field': 'purificationRaw', 'defaultValue': 'PAGE'},
            {'header': '管数 (Tubes)', 'field': 'tubes', 'defaultValue': '1'},
            {'header': '用途/备注 (Notes)', 'field': 'notes', 'defaultValue': ''},
        ],
    },
}

def _resolve_cell_value(col_spec, item, idx, profile, spec):
    field = col_spec.get('field', 'staticDefault')
    default_val = str(col_spec.get('defaultValue', '') or '')
    seq = re.sub(r'[^ACGTUNacgtun]', '', str(item.get('fullSequence') or item.get('sequence') or '')).upper()
    raw_name = str(item.get('name') or f'Primer-{idx + 1}')
    well, plate_id = _well96(idx)
    purity_raw = str(item.get('purity') or profile.get('defaultPurity') or 'PAGE')
    od_raw = item.get('od', profile.get('defaultOD', 2.0))
    try:
        od_fmt = f"{float(od_raw):.1f} OD"
    except Exception:
        od_fmt = str(od_raw)

    val = ''
    if field == 'index1Based':
        val = str(idx + 1)
    elif field == 'name':
        bad = set(spec.get('sanitizeNameChars') or '')
        max_len = int(spec.get('maxNameLength') or 0)
        rep = '_' if ' ' in bad else ''
        val = _sanitize_name(raw_name, bad if bad else None, max_len, rep)
    elif field == 'sanitizedNameIDT':
        val = _sanitize_name(raw_name, IDT_DISALLOWED_CHARS, 0, '')
    elif field == 'sanitizedNameEurofins':
        val = _sanitize_name(raw_name, set(' ,.'), 25, '_')
    elif field == 'sequence':
        val = seq
    elif field == 'length':
        val = str(len(seq))
    elif field == 'well96':
        val = well
    elif field == 'plateID':
        val = plate_id
    elif field == 'scaleIDT':
        val = _idt_scale_from_od(od_raw)
    elif field == 'purificationRaw':
        val = purity_raw
    elif field == 'purificationIDT':
        val = _idt_purification(purity_raw)
    elif field == 'od':
        val = od_fmt
    elif field == 'tubes':
        val = str(item.get('tubes', 1))
    elif field == 'targetPurpose':
        val = str(item.get('targetPurpose') or '')
    elif field == 'notes':
        parts = [str(item.get('targetPurpose') or '').strip(), str(item.get('notes') or '').strip()]
        val = ' | '.join([p for p in parts if p])
    elif field in ('mod5Prime', 'mod3Prime'):
        val = str(item.get(field) or '')
    elif field == 'customerName':
        val = str(profile.get('customerName') or '')
    elif field == 'organization':
        val = str(profile.get('organization') or '')
    elif field == 'staticDefault':
        val = default_val

    return val if val != '' else default_val

def write_table_csv(output_path, headers, rows, delimiter=',', include_header=True):
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    delim = ',' if not delimiter else delimiter
    if delim == '\\t':
        delim = '\t'
    with open(output_path, 'w', encoding='utf-8-sig', newline='') as f:
        writer = csv.writer(f, delimiter=delim, quoting=csv.QUOTE_MINIMAL)
        if include_header and headers:
            writer.writerow(headers)
        for row in rows:
            writer.writerow(row)

def write_table_xlsx(output_path, sheet_name, headers, rows, include_header=True):
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    safe_sheet = re.sub(r'[\\/*?:\[\]]', '_', (sheet_name or 'Order').strip())[:31] or 'Order'

    all_rows = []
    if include_header and headers:
        all_rows.append((headers, True))
    for r in rows:
        all_rows.append((r, False))

    col_count = max([len(headers)] + [len(r) for r in rows] + [1])
    col_widths = [12.0] * col_count
    for r_vals, _ in all_rows:
        for ci, cell_val in enumerate(r_vals):
            txt = str(cell_val or '')
            est = sum(2 if ord(ch) > 127 else 1 for ch in txt) + 3
            col_widths[ci] = min(68.0, max(col_widths[ci], float(est)))

    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>'
    )
    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>'
    )
    wb_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>'
    )
    styles_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2">'
        '<font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><color rgb="FF0F172A"/><name val="Calibri"/></font>'
        '</fonts>'
        '<fills count="3">'
        '<fill><patternFill patternType="none"/></fill>'
        '<fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFE8EEF5"/><bgColor indexed="64"/></patternFill></fill>'
        '</fills>'
        '<borders count="2">'
        '<border><left/><right/><top/><bottom/><diagonal/></border>'
        '<border><left/><right/><top/><bottom style="thin"><color rgb="FFCBD5E1"/></bottom><diagonal/></border>'
        '</borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="2">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>'
        '</cellXfs>'
        '</styleSheet>'
    )

    wb_root = ET.Element(f'{{{NS}}}workbook', {
        'xmlns:r': 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    })
    sheets_el = ET.SubElement(wb_root, f'{{{NS}}}sheets')
    ET.SubElement(sheets_el, f'{{{NS}}}sheet', {
        'name': _clean_xml_text(safe_sheet),
        'sheetId': '1',
        '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id': 'rId1'
    })
    workbook_xml = b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + ET.tostring(wb_root, encoding='utf-8')

    ws_root = ET.Element(f'{{{NS}}}worksheet')
    if include_header and headers:
        sviews = ET.SubElement(ws_root, f'{{{NS}}}sheetViews')
        sv = ET.SubElement(sviews, f'{{{NS}}}sheetView', {'workbookViewId': '0'})
        ET.SubElement(sv, f'{{{NS}}}pane', {
            'ySplit': '1', 'topLeftCell': 'A2', 'activePane': 'bottomLeft', 'state': 'frozen'
        })
    cols_el = ET.SubElement(ws_root, f'{{{NS}}}cols')
    for ci, w in enumerate(col_widths):
        ET.SubElement(cols_el, f'{{{NS}}}col', {
            'min': str(ci + 1), 'max': str(ci + 1), 'width': f'{w:.1f}', 'customWidth': '1'
        })
    sd = ET.SubElement(ws_root, f'{{{NS}}}sheetData')
    for r_idx_1, (r_vals, is_hdr) in enumerate(all_rows, start=1):
        row_el = ET.SubElement(sd, f'{{{NS}}}row', {'r': str(r_idx_1)})
        for c_idx_0, raw_v in enumerate(r_vals):
            ref = f'{_col_letter(c_idx_0)}{r_idx_1}'
            attrs = {'r': ref, 't': 'inlineStr'}
            if is_hdr:
                attrs['s'] = '1'
            c_el = ET.SubElement(row_el, f'{{{NS}}}c', attrs)
            is_el = ET.SubElement(c_el, f'{{{NS}}}is')
            t_el = ET.SubElement(is_el, f'{{{NS}}}t')
            txt = _clean_xml_text(raw_v)
            if txt.startswith(' ') or txt.endswith(' '):
                t_el.set('{http://www.w3.org/XML/1998/namespace}space', 'preserve')
            t_el.text = txt
    sheet_xml = b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + ET.tostring(ws_root, encoding='utf-8')

    with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as zout:
        zout.writestr('[Content_Types].xml', content_types.encode('utf-8'))
        zout.writestr('_rels/.rels', root_rels.encode('utf-8'))
        zout.writestr('xl/workbook.xml', workbook_xml)
        zout.writestr('xl/_rels/workbook.xml.rels', wb_rels.encode('utf-8'))
        zout.writestr('xl/styles.xml', styles_xml.encode('utf-8'))
        zout.writestr('xl/worksheets/sheet1.xml', sheet_xml)

def export_mapped_order(order_type, template_path, output_path, items_data, profile, payload):
    if order_type == 'custom_json':
        spec = payload.get('customTemplate')
        if not spec and template_path and os.path.exists(template_path) and template_path.endswith('.json'):
            with open(template_path, 'r', encoding='utf-8') as tf:
                spec = json.load(tf)
        if not spec or not spec.get('columns'):
            raise ValueError('custom_json requires a valid customTemplate.columns mapping')
    else:
        spec = INTERNATIONAL_PRESETS.get(order_type)
        if spec is None:
            raise ValueError(f'Unknown mapped order type: {order_type}')

    columns = spec.get('columns', [])
    headers = [str(c.get('header') or '') for c in columns]
    rows = [
        [_resolve_cell_value(col, item, idx, profile, spec) for col in columns]
        for idx, item in enumerate(items_data)
    ]

    fmt = str(payload.get('fileFormat') or spec.get('preferredFormat') or '').strip().lower()
    if output_path.lower().endswith('.csv'):
        fmt = 'csv'
    elif output_path.lower().endswith('.xlsx'):
        fmt = 'xlsx'

    include_header = bool(spec.get('includeHeader', True))
    if fmt == 'csv':
        write_table_csv(
            output_path,
            headers,
            rows,
            delimiter=str(spec.get('delimiter') or ','),
            include_header=include_header
        )
    else:
        write_table_xlsx(
            output_path,
            str(spec.get('sheetName') or spec.get('name') or 'Order'),
            headers,
            rows,
            include_header=include_header
        )

if __name__ == '__main__':
    if len(sys.argv) < 5:
        print("Usage: export_order.py <type> <template_path> <output_path> <data_json_path>")
        sys.exit(1)
        
    order_type = sys.argv[1].lower()
    template_path = sys.argv[2]
    output_path = sys.argv[3]
    data_json_path = sys.argv[4]
    
    with open(data_json_path, 'r', encoding='utf-8') as f:
        payload = json.load(f)
        
    profile = payload.get('profile', {})
    items = payload.get('items', [])
    
    if order_type in ('tsingke', 'tsingke_primer'):
        export_tsingke_primer(template_path, output_path, items, profile)
    elif order_type in ('tsingke_seq', 'tsingke_sequencing'):
        export_tsingke_seq(template_path, output_path, items, profile)
    elif order_type in ('sangon', 'sangon_seq'):
        export_sangon_seq(template_path, output_path, items, profile)
    elif order_type in ('sangon_v9', 'sangon_v9_seq'):
        export_sangon_v9_seq(template_path, output_path, items, profile)
    elif order_type in INTERNATIONAL_PRESETS or order_type == 'custom_json':
        export_mapped_order(order_type, template_path, output_path, items, profile, payload)
    else:
        print(f"Unknown order type: {order_type}")
        sys.exit(1)
        
    print(f"Successfully exported to {output_path}")
