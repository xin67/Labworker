<div align="center">

<img src="labworker/Sources/CloneStudioCore/Resources/AppIcon_1024.png" width="116" alt="Labworker App Icon" />

# Labworker

**专为分子生物学与湿实验科研打造的原生 macOS 全栈工作台**  
*分子克隆引物设计 · 环形质粒与双链图谱 · Sanger 四色峰图 · 16-bit WB / 菌落 / qPCR 定量 · 三维蛋白口袋与 AI MCP 协同*

[![Version](https://img.shields.io/badge/Release-v20261115-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/xin67/Labworker/releases/tag/v20261115)
[![macOS](https://img.shields.io/badge/macOS-27.0%2B%20Liquid%20Glass-1D1D1F?style=for-the-badge)](https://github.com/xin67/Labworker/releases/tag/v20261115)
[![Swift](https://img.shields.io/badge/Swift-6.4%20%7C%20Zero%203rd--Party%20Deps-F05138?style=for-the-badge&logo=swift&logoColor=white)](#-架构设计与协同工作流)
[![MCP](https://img.shields.io/badge/MCP%20Tools-23%20Ready-30D158?style=for-the-badge)](#-ai-智能体协同)
[![License](https://img.shields.io/badge/License-MIT-8E8E93?style=for-the-badge)](LICENSE)

[⬇️ 下载最新版 DMG (`v20261115`)](https://github.com/xin67/Labworker/releases/tag/v20261115) &nbsp;·&nbsp; [📸 实机界面画廊](#-实机界面与核心能力展示) &nbsp;·&nbsp; [🧩 20 个功能模块](#-20-个全栈功能模块) &nbsp;·&nbsp; [🤖 MCP 智能体接入](#-ai-智能体协同) &nbsp;·&nbsp; [🔧 源码构建](#-安装与源码构建)

<br/>

<img src="docs/images/01-single-clone-map.png" width="100%" alt="Labworker 单片段无缝克隆与质粒全景图谱" />

<sub>▲ 单片段无缝克隆工作台与「精细同屏」双视角预览：左侧设计 15–25 bp 同源重组引物并实时校验 3n 阅读框，右侧同步联动 OVE 环形质粒图谱与双链碱基/氨基酸序列画布（内置公开示例演示）。</sub>

</div>

---

## ✨ 为什么选择 Labworker？

- **🎨 原生 macOS 27 Liquid Glass 体验**：纯 SwiftUI + AppKit 构建，深浅色与系统强调色实时跟随，统一 macOS 系统字体与 `.monospacedDigit()` 等宽数值排版；支持将 `.dna`、`.ab1`、`.tif`、`.pdb` 等文件从 Finder 直接拖入或右键打开自动跳转对应模块。
- **⚡️ 零第三方 Swift 依赖 · 本地硬件加速**：底层完全依托 Apple 原生 `Accelerate/vDSP`、`SQLite3` 与本地计算引擎离线运行——**实验序列与原始图像无需离开本机**。
- **🔬 对齐期刊审稿标准的湿实验统计**：内置 SantaLucia 最近邻 $T_m$ 与二级结构 $\Delta G$ 计算、Rolling-Ball 背景扣减、Otsu + 分水岭粘连拆解、Garwood 95% 泊松置信区间、Welch's *t*-test 及 Holm–Bonferroni 多重检验校正。
- **🤖 开箱即用的 AI MCP 双端协同**：随包内置 `clonestudio_mcp_server.py`（**23** 个工具），可直接接入 Claude Desktop、Cursor、Windsurf、Antigravity 等 AI 客户端，实现自动化引物设计、测序 QC 与工作台联动同步。

---

## 📸 实机界面与核心能力展示

以下全部截图均采集自 **`Labworker v20261115`（macOS 实机浅色 Liquid Glass 主题）** 运行内置公开示范数据的真实界面：

<table>
  <tr>
    <td width="50%" valign="top">
      <a href="docs/images/02-sanger-verify.png">
        <img src="docs/images/02-sanger-verify.png" width="100%" alt="Sanger 测序四色峰图与质粒比对验证" />
      </a>
      <h4>🧬 Sanger 测序 (<code>.ab1</code>) 四色峰图与突变验证</h4>
      <ul>
        <li>原生解析二进制 <code>ABIF</code> 四通道（<code>A/C/G/T</code>）毛细管电泳峰图与 Phred 质量评分</li>
        <li>支持峰距缩放、<code>5'/3'</code> Q20 质量阈值修剪、环状质粒双向全局比对</li>
        <li>自动检出 SNP 点突变、InDel 与杂合双峰预警，并支持批量克隆验证看板</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <a href="docs/images/03-western-blot.png">
        <img src="docs/images/03-western-blot.png" width="100%" alt="16-bit Western Blot 灰度定量与明场叠合" />
      </a>
      <h4>📊 16-bit Western Blot 灰度定量与明场叠合</h4>
      <ul>
        <li>无损读取原始 <code>16-bit / 8-bit TIFF</code> 化学发光图，支持与明场 Marker 图层叠合</li>
        <li>可调半径 <code>Rolling-Ball</code> 背景扣除、自动切分泳道/条带框与过曝像素掩码高亮</li>
        <li>实时渲染条带光密度剖面峰图、计算内参归一化倍数与统计学显著性报告</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <a href="docs/images/04-protein-workbench.png">
        <img src="docs/images/04-protein-workbench.png" width="100%" alt="三维蛋白骨架视窗与 AutoDock Vina 对接盒" />
      </a>
      <h4>🧊 三维蛋白骨架、LIGSITE 口袋与 Vina 对接盒</h4>
      <ul>
        <li>三维 Cα 骨架交互视窗，支持按 <code>pLDDT</code>、二级结构、疏水性与结合口袋实时着色</li>
        <li>计算分子量、理论等电点 ($pI$)、消光系数 $\varepsilon_{280}$、GRAVY 与不稳定指数</li>
        <li>七方向 LIGSITE P-S-P 几何扫描定位结合口袋，一键导出 <code>vina_config.txt</code> 与拉氏构象图</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <a href="docs/images/05-colony-counter.png">
        <img src="docs/images/05-colony-counter.png" width="100%" alt="菌落计数器与 X-gal 蓝白斑筛选" />
      </a>
      <h4>🧫 菌落计数器 (CFU) 与蓝白斑筛选</h4>
      <ul>
        <li>自适应 <code>Otsu</code> 阈值分割 + 形态学分水岭算法自动拆解粘连菌落</li>
        <li>结合 HSV 色彩空间智能区分阳性白斑 (<code>LacZ-</code>) 与自连蓝斑 (<code>LacZ+</code>)</li>
        <li>支持画布点击排除/手动补加白蓝斑，同步输出 <code>CFU/mL</code> 滴度与 Garwood 95% 泊松置信区间</li>
      </ul>
    </td>
  </tr>
</table>

<details open>
<summary><b>📈 qPCR 荧光定量、QC 质控与 Welch's <i>t</i>-test 多组统计（点击展开/收起）</b></summary>
<br/>
<a href="docs/images/06-qpcr-analysis.png">
  <img src="docs/images/06-qpcr-analysis.png" width="100%" alt="qPCR 荧光定量分析与 ΔCt 热图矩阵" />
</a>
<br/>
<sub>▲ 支持 <code>2^(-ΔΔCt)</code> 相对定量与标准曲线绝对定量，具备多内参几何平均、扩增效率校正、高 Ct / NTC / 复孔 SD > 0.30 离群风险排查、<code>ΔCt</code> 热图矩阵及基于生物学重复级别的 Welch's <i>t</i>-test + Holm–Bonferroni 多组校正。</sub>
</details>

---

## 📐 架构设计与协同工作流

```mermaid
flowchart LR
    subgraph Input["📂 多源科研数据输入 (Finder 拖放 / 双击路由)"]
        I1[".dna / .gb / .fasta\n质粒与序列"]
        I2[".ab1 / .abi\nSanger 测序"]
        I3["16-bit .tif / .png\nWB / 胶图 / 菌落"]
        I4[".pdb / .cif / .csv\n蛋白结构 / qPCR"]
    end

    subgraph Core["⚙️ 原生 Swift 计算内核 (CloneStudioCore · 零第三方依赖)"]
        C1["分子克隆与引物引擎\nSantaLucia Tm · 二聚体/发夹 ΔG"]
        C2["生物图像与峰图引擎\nAccelerate/vDSP · Rolling-Ball · 分水岭 · ABIF"]
        C3["结构与统计引擎\nLIGSITE 口袋 · Welch t · Holm · 泊松 CI"]
        C4["Offline Libraries.sqlite\nhg38 / mm39 离线靶点与酶库"]
    end

    subgraph Surfaces["🖥️ 交互与自动化双端面"]
        S1["macOS 27 Liquid Glass App\n5 大分类 · 20 个功能模块"]
        S2["Python MCP Server\n23 大自动化工具 · 双向同步通道"]
    end

    subgraph Out["📤 学术交付与实验产出"]
        O1["擎科 / 生工标准订购表 (.xlsx)"]
        O2["SnapGene 重组 .dna & Vina 配置"]
        O3["离线 HTML 统计报告 & CSV 数据"]
    end

    Input --> Core
    Core --> S1
    Core <--> S2
    S1 --> Out
    S2 --> Out
```

> 更多工程架构细节与单源真值校验契约，请参阅仓库内部文档：[`labworker/README.md`](labworker/README.md) · [`labworker/ARCHITECTURE.md`](labworker/ARCHITECTURE.md) · [`labworker/HANDOVER.md`](labworker/HANDOVER.md)

---

## 🧩 20 个全栈功能模块

| 分类板块 | 模块名称 | 核心功能与支持格式 |
| :--- | :--- | :--- |
| **分子克隆与质粒 (7)** | `质粒池` / `入门克隆` / `单片段克隆` / `多片段克隆` / `定点突变` / `片段删除` / `Sanger 测序` | `.dna` (SnapGene)、`.gb`、`.fasta`、`.ab1` 解析与导出；支持矢量环形图谱、双链碱基视图、同源重组 PCR 凝胶电泳模拟、3n 移码校验与批量测序看板 |
| **基因编辑与靶点 (3)** | `sgRNA 设计` / `shRNA 设计` / `靶点对比` | 基于 `Libraries.sqlite`（hg38/mm39）扫描 `NGG/TTTV` PAM、热力学不对称性与 CHOPCHOP 靶点分档比对，自动带酶切粘性末端 |
| **电泳与图像定量 (3)** | `WB 灰度定量` / `凝胶分子量` / `菌落计数器` | 原生 16-bit TIFF 滚球扣背景与显著性柱状图、Ladder $\log_{10}(\text{MW})$ 回归、Otsu+分水岭蓝白斑统计 |
| **定量与蛋白工具 (3)** | `微孔板设计` / `qPCR 定量` / `蛋白工作台` | 96/384 孔防边缘效应排布、$2^{-\Delta\Delta C_t}$ 与标准曲线定量、三维 Cα + LIGSITE 口袋 + Vina 盒 + 点突变 $\Delta\Delta G$ |
| **工具、订购与系统 (4)** | `生物计算器` / `序列工具箱` / `引物测序订购` / `全局设置` | 克隆与经典 0.03 pmol 摩尔比配液、dsDNA/ssDNA/Linear/OD260 核酸定量、蛋白摩尔与编码容量、溶液配制/稀释 ($C_1V_1=C_2V_2$)/温标转换；SantaLucia 速算、Excel 订购单与主题管理 |

---

## 🤖 AI 智能体协同

`Labworker.app` 内部打包了开箱即用的 `clonestudio_mcp_server.py`（通过标准 `stdio` MCP 协议提供 **23** 个结构化科研工具），兼容 Claude Desktop、Cursor、Windsurf、Antigravity 与 Codex CLI。

<details>
<summary><b>查看 MCP 客户端接入配置与 23 项内置工具清单</b></summary>

在你的 AI 客户端 MCP 配置文件（例如 `mcp_config.json`）中添加以下配置（安装至 `/Applications/Labworker.app` 后无需额外依赖环境）：

```json
{
  "mcpServers": {
    "labworker-mcp": {
      "command": "/usr/bin/python3",
      "args": [
        "/Applications/Labworker.app/Contents/Resources/clonestudio_mcp_server.py"
      ]
    }
  }
}
```

**23 项可用工具覆盖全流程**：
- **质粒池与序列检索**：`list_plasmid_pool`、`inspect_plasmid`、`add_plasmid_to_pool`、`auto_annotate_sequence`
- **克隆与基因编辑设计**：`design_single_clone_primers`、`design_multi_fragment_primers`、`design_golden_gate_assembly`、`design_mutagenesis_primers`、`design_fragment_deletion_primers`、`calculate_recombination_dosage`、`design_sgrna_primers`、`design_shrna_primers`、`design_hdr_donor`
- **生物换算与溶液配置**：`convert_nucleic_acid_units`、`convert_protein_and_coding`、`calculate_solution_and_temperature`
- **测序、蛋白与湿实验定量**：`verify_sanger_sequencing`、`deconvolute_crispr_sanger`、`analyze_protein_and_docking_box`、`analyze_western_blot`、`analyze_qpcr_ddct`、`design_plate_layout`
- **订购交付**：`manage_primer_cart_and_export`

</details>

---

## 🔧 安装与源码构建

### 方式 A：直接安装发布版 DMG（推荐）

1. 前往 [**GitHub Releases (`v20261115`)**](https://github.com/xin67/Labworker/releases/tag/v20261115) 下载 `Labworker-20261115.dmg`。
2. 双击打开 DMG 镜像，将 `Labworker.app` 拖入 `/Applications` 文件夹。
3. 要求系统环境：**`macOS 27.0` 及以上**。

### 方式 B：从源码编译、打包与回归测试

```bash
git clone https://github.com/xin67/Labworker.git
cd Labworker/labworker

# 1. 运行全部 51 项底层算法与跨语言测试向量（含文档单一真值门禁）
bash Scripts/check_doc_counts.sh

# 2. Release 编译并打包 Labworker.app（自动完成 Ad-hoc 签名校验）
bash Scripts/build_app.sh

# 3. 打包标准可分发 DMG 镜像（输出 Labworker-20261115.dmg 并校验 SHA-256）
bash Scripts/package_dmg.sh
```

> **提示**：仓库已配置 `.gitignore`，所有本地 `.dna` / `.ab1` 序列及私有质粒库记录（`.clonestudio_plasmid_pool.json`）均仅留存于用户本地，不会随代码提交上传。

---

## 📄 开源协议

本项目基于 [MIT License](LICENSE) 开源发布。欢迎提交 Issue 或 Pull Request 共建更好用的原生科研工具链。
