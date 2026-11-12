#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Excel Order Form Generator for CloneStudio macOS
Handles:
1. 擎科引物合成订购表.xlsx
2. 擎科测序订购表专属电子订单.xlsx
3. 生工DNA测序订购表.xlsx
4. DNA测序订购表_V9(1).xlsx (生工通用 V9 版)
Preserves original template formatting, styles, borders, and formulas.
"""

import sys
import os
import json
import zipfile
import tempfile
import xml.etree.ElementTree as ET

NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
ET.register_namespace('', NS)

DEFAULT_UNIFIED_ADDRESS = '生命科学园区实验楼A座'

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
    else:
        print(f"Unknown order type: {order_type}")
        sys.exit(1)
        
    print(f"Successfully exported to {output_path}")
