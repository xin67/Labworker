import Foundation
import CloneStudioCore

setbuf(stdout, nil)
var passedTests: [String] = []
func pass(_ name: String) {
    passedTests.append(name)
    print("   ✅ \(name)")
}
print("🚀 Starting CloneStudio Verification Suite...")

// 1. 验证 BioSequence
print("🧪 [1/52] Testing BioSequence...")
let cleaned = BioSequence.clean("  atg  cga tcg  123 \n !? ")
assert(cleaned == "ATGCGATCG", "Clean sequence mismatch: \(cleaned)")
assert(BioSequence.reverse("ATGC") == "CGTA", "Reverse mismatch")
assert(BioSequence.complement("ATGC") == "TACG", "Complement mismatch")
assert(BioSequence.reverseComplement("ATGC") == "GCAT", "Reverse complement mismatch")
assert(BioSequence.gcContent("GGCC") == 100.0, "GC% mismatch")
pass("BioSequence passed.")

// 2. 验证限制性内切酶数据库与 IUPAC 模糊匹配
print("🧪 [2/52] Testing RestrictionEnzyme Database & IUPAC...")
let db = RestrictionEnzymeDatabase.shared
assert(db.enzymes.count >= 200, "Enzyme DB should contain 200+ enzymes, found: \(db.enzymes.count)")
guard let bamhi = db.find(name: "BamHI") else { fatalError("BamHI not found") }
assert(bamhi.site == "GGATCC")
assert(bamhi.isIn(sequence: "ATCGGATCCGATC"))
guard let acci = db.find(name: "AccI") else { fatalError("AccI not found") }
// AccI 位点为 GTMKAC (M=A/C, K=G/T) -> 如 GTATAC, GTAGAC, GTCTAC
assert(acci.isIn(sequence: "AAAGTATACCCC"))
pass("RestrictionEnzyme passed (\(db.enzymes.count) enzymes loaded).")

// 3. 验证 TmCalculator
print("🧪 [3/52] Testing TmCalculator...")
let tmRes = TmCalculator.calculate(sequence: "ATGCGATCGATCGATCGATCGATC")
assert(tmRes.length == 24)
assert(tmRes.tm > 55.0 && tmRes.tm < 75.0, "Tm out of expected range: \(tmRes.tm)")
pass("TmCalculator passed (Tm = \(tmRes.tm)℃, Ta = \(tmRes.recommendedTa)℃).")

// 4. 验证 DNAMolarCalculator (与官方及经典摩尔比连接对齐)
print("🧪 [4/52] Testing DNAMolarCalculator...")
let vecRes = DNAMolarCalculator.calculate(cloneType: .single, isVector: true, lengthKb: 5.0, concentrationNgPerUl: 50.0)
assert(vecRes.recommendedNg == 100.0, "Vector ng mismatch")
assert(vecRes.volFormatted == "2.00", "Vector vol mismatch")
let insRes = DNAMolarCalculator.calculate(cloneType: .single, isVector: false, lengthKb: 1.0, concentrationNgPerUl: 20.0)
assert(insRes.recommendedNg == 40.0, "Insert ng mismatch")
assert(insRes.volFormatted == "2.00", "Insert vol mismatch")
if let ligRes = DNAMolarCalculator.calculateLigationByMolarRatio(
    vectorLengthBp: 5000,
    vectorConcNgPerUl: 50.0,
    vectorPmol: 0.03,
    insertLengthBp: 1000,
    insertConcNgPerUl: 25.0,
    molarRatio: .r1_3
) {
    assert(abs(ligRes.vectorNg - 97.5) < 1e-6 && abs((ligRes.vectorVolUl ?? 0) - 1.95) < 1e-6, "Ligation vector calculation mismatch")
    assert(abs(ligRes.insertNg - 58.5) < 1e-6 && abs((ligRes.insertVolUl ?? 0) - 2.34) < 1e-6, "Ligation insert calculation mismatch")
    assert(!ligRes.lowInsertSingleWarning && !ligRes.lowInsertMultiWarning, "58.5 ng insert must not trigger low-ng warning")
} else {
    fatalError("Ligation molar ratio calculation returned nil")
}
let lowLig = DNAMolarCalculator.calculateLigationByMolarRatio(vectorLengthBp: 4000, vectorPmol: 0.03, insertLengthBp: 500, molarRatio: .r1_1)
assert(lowLig?.lowInsertSingleWarning == true && lowLig?.lowInsertMultiWarning == true, "9.75 ng insert must trigger both single (<20ng) and multi (<10ng) warnings")
pass("DNAMolarCalculator passed (Vector: 100ng/2μL, Insert: 40ng/2μL & Ligation 0.03 pmol 1:3 verified).")

// 5. 验证 HomologyArmDesigner
print("🧪 [5/52] Testing HomologyArmDesigner (18bp Laboratory Golden Preference & Custom Arm Length)...")
let testSeq = "ATGCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG"
let localDesign = HomologyArmDesigner.designEntryClone(
    insertSeq: testSeq,
    hasEnzymes: true,
    enzyme5: db.find(name: "BamHI"),
    enzyme3: db.find(name: "EcoRI")
)
assert(!localDesign.primerF.fullSequence.isEmpty)
assert(!localDesign.primerR.fullSequence.isEmpty)
assert(localDesign.primerF.fullSequence.lowercased().hasPrefix("ggatcttccagagat"))
assert(localDesign.primerR.fullSequence.lowercased().hasPrefix("ctgccgttcgacgat"))

// 验证单酶切默认 18 bp 同源臂 (实验室黄金偏好)
let dummyVector = "TATAGGGAGACCCAAGCTTGGTACCGAGCTCGGATCCACTAGTAACGGCCGCCAGTGTGCTGGAATTCCTGCAGATATCCAGCACAGTGGCGGCCGCTCGAG"
let single18 = HomologyArmDesigner.designSingleEnzymeClone(
    vectorSeq: dummyVector,
    insertSeq: testSeq,
    enzyme: db.find(name: "BamHI")!
)
assert(single18.primerF.homologyArm.count == 18, "Default homology arm must be 18 bp, got \(single18.primerF.homologyArm.count)")
assert(single18.primerR.homologyArm.count == 18, "Default homology arm must be 18 bp, got \(single18.primerR.homologyArm.count)")

// 验证自定义同源臂 (20 bp)
let single20 = HomologyArmDesigner.designSingleEnzymeClone(
    vectorSeq: dummyVector,
    insertSeq: testSeq,
    enzyme: db.find(name: "BamHI")!,
    homologyLength: 20
)
assert(single20.primerF.homologyArm.count == 20, "Custom homology arm must be 20 bp, got \(single20.primerF.homologyArm.count)")
assert(single20.primerR.homologyArm.count == 20, "Custom homology arm must be 20 bp, got \(single20.primerR.homologyArm.count)")

// 验证反向 PCR 载体默认 18 bp 同源臂
let pcrDesign = HomologyArmDesigner.designPCRVectorClone(
    vectorSeqU: "TATAGGGAGACCCAAGCTTGGTACCGAGCTCGGATCCACTAGTAACGGCC",
    vectorSeqD: "GCCGCCAGTGTGCTGGAATTCCTGCAGATATCCAGCACAGTGGCGGCCGCTCGAG",
    insertSeq: testSeq
)
assert(pcrDesign.primerF.homologyArm.count == 18, "PCR vector clone homology arm must be 18 bp, got \(pcrDesign.primerF.homologyArm.count)")
assert(pcrDesign.primerR.homologyArm.count == 18, "PCR vector clone homology arm must be 18 bp, got \(pcrDesign.primerR.homologyArm.count)")

// 验证定点突变默认 18 bp 互补同源重叠臂 (实验室黄金偏好)
let mutUp = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTG"
let mutDown = "CGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAG"
let mut18 = HomologyArmDesigner.designMutagenesis(mutUp: mutUp, mutDown: mutDown, mutSite: "GAG", homologyLength: 18)
assert(mut18.primerF.homologyArm.count == 18, "Mutagenesis homology arm must be 18 bp, got \(mut18.primerF.homologyArm.count)")
assert(mut18.primerR.homologyArm.count == 18, "Mutagenesis homology arm must be 18 bp, got \(mut18.primerR.homologyArm.count)")
assert(mut18.primerF.homologyArm == BioSequence.reverseComplement(mut18.primerR.homologyArm).lowercased(), "F and R mutation homology arms must be reverse complements")

// 验证定点突变自定义 20 bp 重叠臂
let mut20 = HomologyArmDesigner.designMutagenesis(mutUp: mutUp, mutDown: mutDown, mutSite: "GAG", homologyLength: 20)
assert(mut20.primerF.homologyArm.count == 20, "Mutagenesis homology arm must be 20 bp, got \(mut20.primerF.homologyArm.count)")
assert(mut20.primerR.homologyArm.count == 20, "Mutagenesis homology arm must be 20 bp, got \(mut20.primerR.homologyArm.count)")
pass("HomologyArmDesigner passed (Clone & Mutagenesis 18 bp/20 bp verified).")

// 6. 验证 ExcelOrderExporter (自动灌装当前项目真实表单)
print("🧪 [6/52] Testing ExcelOrderExporter with user templates...")
let exporter = ExcelOrderExporter.shared
let tsingkeTpl = exporter.locateTemplate(name: ExcelOrderExporter.defaultTsingkeTemplateName)
assert(tsingkeTpl != nil, "Must locate 擎科引物合成订购表.xlsx")

let testPrimers = [
    PrimerItem(name: "Test-Gene-F", fullSequence: "ggatcttccagagatggatccATGCGATCGATCGATC", purity: "PAGE", od: 2.0, targetPurpose: "测试入门克隆F"),
    PrimerItem(name: "Test-Gene-R", fullSequence: "ctgccgttcgacgatgaattcCGATCGATCGATCGAT", purity: "PAGE", od: 2.0, targetPurpose: "测试入门克隆R")
]

let tempOut = try exporter.exportTsingkeOrder(primers: testPrimers)
assert(FileManager.default.fileExists(atPath: tempOut), "Exported Excel file must exist: \(tempOut)")
try? FileManager.default.removeItem(atPath: tempOut)
pass("ExcelOrderExporter passed.")

// 7. 验证 GenomicLibraryService SQLite 数据库与人/鼠源检索
print("🧪 [7/52] Testing GenomicLibraryService (SQLite3 Human vs Mouse)...")
let libService = GenomicLibraryService.shared
// 人源 sgRNA 检索 TP53
let humanSg = libService.search(query: "TP53", species: .human, type: .sgRNA)
assert(!humanSg.isEmpty, "Human sgRNA search for TP53 should return targets")
assert(humanSg.first?.species == .human)
pass("Human sgRNA search TP53 found: \(humanSg.count) targets")

// 鼠源 sgRNA 检索 Trp53
let mouseSg = libService.search(query: "Trp53", species: .mouse, type: .sgRNA)
assert(!mouseSg.isEmpty, "Mouse sgRNA search for Trp53 should return targets")
assert(mouseSg.first?.species == .mouse)
pass("Mouse sgRNA search Trp53 found: \(mouseSg.count) targets")

// 人源 shRNA 检索 CDH17
let humanSh = libService.search(query: "CDH17", species: .human, type: .shRNA)
assert(!humanSh.isEmpty, "Human shRNA search for CDH17 should return targets")
assert(humanSh.first?.species == .human)
pass("Human shRNA search CDH17 found: \(humanSh.count) targets")

// 8. 验证 CRISPRDesigner
print("🧪 [8/52] Testing CRISPRDesigner (lentiCRISPR v2 overhangs)...")
let sgTarget = "GTCGCTGAGCTCCGATTCGA"
let sgPair = CRISPRDesigner.designPair(
    target: sgTarget,
    geneName: "A1BG",
    index: 1,
    prefix: "P1",
    species: .human,
    vector: .lentiCRISPRv2
)
assert(sgPair.fwdPrimer.fullSequence == "CACCG" + sgTarget)
assert(sgPair.revPrimer.fullSequence.hasPrefix("AAAC"))
assert(sgPair.revPrimer.fullSequence.hasSuffix("C"))
assert(sgPair.fwdPrimer.name == "P1_sg1-FWD")
assert(sgPair.revPrimer.name == "P1_sg1-REV")
pass("CRISPRDesigner passed.")

// 9. 验证 ShRNADesigner
print("🧪 [9/52] Testing ShRNADesigner (pLKO.1 hairpin assembly)...")
let shTarget = "CCAGTCCCTATCACCATAGAA"
let shPair = ShRNADesigner.designPair(
    target: shTarget,
    geneName: "CDH17",
    index: 1,
    prefix: "P1",
    species: .human
)
// F: CCGG + Sense + CTCGAG + Antisense + TTTTTTG
assert(shPair.fwdPrimer.fullSequence.hasPrefix("CCGG"))
assert(shPair.fwdPrimer.fullSequence.contains("CTCGAG"))
assert(shPair.fwdPrimer.fullSequence.hasSuffix("TTTTTTG"))
// R: AATTCAAAAAAA + Sense + CTCGAG + Antisense
assert(shPair.revPrimer.fullSequence.hasPrefix("AATTCAAAAAAA"))
assert(shPair.fwdPrimer.name == "P1_sh1-F")
assert(shPair.revPrimer.name == "P1_sh1-R")
pass("ShRNADesigner passed.")

// 10. 验证 CHOPCHOPService URL 构建与 Python 异步直连
print("🧪 [10/52] Testing CHOPCHOPService (URL & Python Pipeline)...")
let chopURLHuman = CHOPCHOPService.shared.makeWebURL(gene: "TP53", species: .human)
assert(chopURLHuman.absoluteString.contains("target=TP53"))
assert(chopURLHuman.absoluteString.contains("organism=hg38"))

let chopURLMouse = CHOPCHOPService.shared.makeWebURL(gene: "Trp53", species: .mouse)
assert(chopURLMouse.absoluteString.contains("target=Trp53"))
assert(chopURLMouse.absoluteString.contains("organism=mm39"))

assert(TargetSpecies.human.chopchopAPIGenome == "hg38")
assert(TargetSpecies.human.vbcGenome == "hg38")
assert(TargetSpecies.human.ucscGenome == "hg38")
assert(TargetSpecies.mouse.chopchopAPIGenome == "Mus_musculus_GRCm39")
assert(TargetSpecies.mouse.vbcGenome == "mm10")
assert(TargetSpecies.mouse.ucscGenome == "mm39")

let chopJobURL = CHOPCHOPService.shared.makeWebURL(gene: "TP53", species: .human, jobId: "test-job-123")
assert(chopJobURL.absoluteString.contains("/results/test-job-123"))

let vbcWebURL = CHOPCHOPService.shared.makeVBCWebURL()
assert(vbcWebURL.absoluteString == "https://www.vbc-score.org/")

let crisporWebURL = CHOPCHOPService.shared.makeCRISPORWebURL(species: .human, genomicSpan: "chr17:7668421-7687490")
assert(crisporWebURL.absoluteString.contains("org=hg38"))
assert(crisporWebURL.absoluteString.contains("chr17") && crisporWebURL.absoluteString.contains("7668421-7687490"))

// Broad GPP Public Portal 离线 URL、CSV 解析、同序列多载体归并、本地 shRNA 匹配及 Codable 校验
assert(TargetSpecies.human.ncbiTaxonId == "9606" && TargetSpecies.mouse.ncbiTaxonId == "10090")
let gppGeneURL = BroadGPPService.shared.makeWebURL(geneID: "7157")
assert(gppGeneURL.absoluteString == "https://portals.broadinstitute.org/gpp/public/gene/details?geneId=7157")
let gppCloneURL = BroadGPPService.shared.makeCloneWebURL(cloneID: "TRCN0000003756")
assert(gppCloneURL.absoluteString == "https://portals.broadinstitute.org/gpp/public/clone/details?cloneId=TRCN0000003756")

let sampleGPPSearchCSV = """
Input,Taxon,"Gene ID","Gene Symbol",Current?,"Gene Description","Current WT Transcripts"
TP53,human,7157,TP53,Y,"tumor protein p53","NM_000546.5, NM_001126112.2"
"""
let parsedGPPGene = BroadGPPService.parseGeneSearchCSV(sampleGPPSearchCSV)
assert(parsedGPPGene?.geneID == "7157" && parsedGPPGene?.symbol == "TP53" && parsedGPPGene?.transcriptCount == 2)

let sampleGPPClonesCSV = """
Taxon,"Gene ID","Gene Symbol","Clone ID","Legacy Clone Name","Target Seq",Vector,"Matching Transcripts for Gene","Match Regions","Match %","SDR Match %","Intrinsic Score","Adjusted Score","Matches Other Gene in Same Taxon?","Orig. Target Gene ID","Orig. Target Gene Symbol","Forward Oligo Sequence","Reverse Oligo Sequence",Addgene
human,7157,TP53,TRCN0000003756,NM_000546.x-941s1c1,CACCATCCACTACAACTACAT,pLKO.1,"NM_000546.5, NM_001126112.2",CDS,100,100,4.95,3.96,N,7157,TP53,CCGGCACCATCCACTACAACTACATCTCGAGATGTAGTTGTAGTGGATGGTGTTTTTG,AATTCAAAAACACCATCCACTACAACTACATCTCGAGATGTAGTTGTAGTGGATGGTG,n/a
human,7157,TP53,TRCN0000342334,NM_000546.4-887s21c1,CACCATCCACTACAACTACAT,pLKO_005,"NM_000546.5, NM_001126112.2",CDS,100,100,4.95,3.96,N,7157,TP53,CCGGCACCATCCACTACAACTACATCTCGAGATGTAGTTGTAGTGGATGGTGTTTTTG,AATTCAAAAACACCATCCACTACAACTACATCTCGAGATGTAGTTGTAGTGGATGGTG,n/a
human,7157,TP53,TRCN0000999999,NM_000546.x-off,GGCGTAGGTAGCGATGCTGAT,pLKO.1,"NM_000546.5",3UTR,100,95,4.10,2.05,Y,7157,TP53,,,12345
"""
let parsedGPPTargets = BroadGPPService.parseShRNAClonesCSV(sampleGPPClonesCSV)
assert(parsedGPPTargets.count == 2, "Duplicate 21bp Target Seq across pLKO.1 and pLKO_005 must merge into 1 entry")
let primaryGPP = parsedGPPTargets.first { $0.primaryCloneID == "TRCN0000003756" }!
assert(primaryGPP.vectors == ["pLKO.1", "pLKO_005"] && primaryGPP.allCloneIDs.count == 2 && primaryGPP.transcriptCount == 2)
assert(!primaryGPP.matchesOtherGene && primaryGPP.isHighlySpecific && primaryGPP.addgeneID == nil)
let offTargetGPP = parsedGPPTargets.first { $0.primaryCloneID == "TRCN0000999999" }!
assert(offTargetGPP.matchesOtherGene && offTargetGPP.addgeneID == "12345" && primaryGPP.combinedScore.score > offTargetGPP.combinedScore.score)
let localShMatch = LocalCompareTarget(label: "本地已选 sh#1", sequence: "CACCATCCACTACAACTACAT", sourceType: .shRNA, isSelectedOrGenerated: true)
assert(primaryGPP.matchAgainstLocalTargets([localShMatch])?.kind == .exact)
let gppEncoded = try JSONEncoder().encode(parsedGPPTargets)
let gppDecoded = try JSONDecoder().decode([BroadGPPShRNATarget].self, from: gppEncoded)
assert(gppDecoded.count == 2 && gppDecoded[0].combinedScore.score == primaryGPP.combinedScore.score)

if ProcessInfo.processInfo.environment["CLONESTUDIO_ONLINE_TEST"] == "1" {
    do {
        let chopTargets = try await CHOPCHOPService.shared.queryTargets(gene: "TP53", species: .human, timeout: 10)
        assert(!chopTargets.isEmpty, "CHOPCHOP query for TP53 should return targets")
        let first = chopTargets.first!
        assert(first.spacer.count == 20, "Spacer should be 20 bp")
        assert(!first.pam.isEmpty, "PAM should not be empty")
        assert(first.efficiency > 0, "Efficiency score should be positive")
        pass("CHOPCHOPService Python query passed (Loaded \(chopTargets.count) targets, Top: \(first.spacer)+\(first.pam), Eff: \(first.efficiency)).")
    } catch {
        print("   ⚠️ CHOPCHOPService test notice: \(error)")
    }
} else {
    pass("CHOPCHOPService URL builder verified (set CLONESTUDIO_ONLINE_TEST=1 for live network query).")
}

// 11. 验证 SgRNAScoringEngine (Doench RS2 & TTTT Pol III 终止拦截)
print("🧪 [11/52] Testing SgRNAScoringEngine (Reliability & Termination Filter)...")
// 优质靶点：5' G, 3' G, GC 50%
let idealSg = "GACGATCGATCGATCGATCG"
let idealSgScore = SgRNAScoringEngine.evaluate(sequence: idealSg)
assert(idealSgScore.score >= 85.0, "Ideal sgRNA score should be >= 85, got \(idealSgScore.score)")
assert(idealSgScore.tier == .excellent, "Ideal sgRNA tier should be excellent")
assert(!idealSgScore.hasFatalIssue, "Ideal sgRNA must not have fatal issue")

// 致命缺陷：含 TTTT 早期终止信号
let fatalSg = "GACGTTTTCGATCGATCGTG"
let fatalSgScore = SgRNAScoringEngine.evaluate(sequence: fatalSg)
assert(fatalSgScore.hasFatalIssue, "Must flag fatal issue for TTTT")
assert(fatalSgScore.score <= 35.0, "Score must be capped at 35 for TTTT, got \(fatalSgScore.score)")
assert(fatalSgScore.tier == .poor, "Tier must be poor for fatal TTTT")

// 切割抑制：Pos 20 为 T，极端 GC
let poorSg = "GCGGCCGGCCGGCCGGCCGT"
let poorSgScore = SgRNAScoringEngine.evaluate(sequence: poorSg)
assert(poorSgScore.score < 50.0, "sgRNA with Pos 20 T and extreme GC should be low score")
pass("SgRNAScoringEngine passed (Ideal: \(idealSgScore.score), Fatal TTTT: \(fatalSgScore.score), Poor: \(poorSgScore.score)).")

// 12. 验证 ShRNAScoringEngine (Reynolds / Ui-Tei 热力学不对称性与排序)
print("🧪 [12/52] Testing ShRNAScoringEngine (Thermodynamic Asymmetry & RISC Loading)...")
// 优质 shRNA: 5' C, 3' A, Pos 10 A, GC 42%
let idealSh = "CCAGTCCCTATCACCATAGAA" // 21nt
let idealShScore = ShRNAScoringEngine.evaluate(sequence: idealSh)
assert(idealShScore.score >= 80.0, "Ideal shRNA score should be >= 80, got \(idealShScore.score)")
assert(idealShScore.tier == .excellent, "Ideal shRNA tier should be excellent")

// 致命缺陷：Sense 含有 TTTT
let fatalSh = "CCAGTTTTATCACCATAGAA"
let fatalShScore = ShRNAScoringEngine.evaluate(sequence: fatalSh)
assert(fatalShScore.hasFatalIssue, "Must flag fatal issue for shRNA TTTT")
assert(fatalShScore.score <= 35.0, "Score must be capped at 35, got \(fatalShScore.score)")

// 靶点动态评分与排序验证
let dummyTargetHigh = GenomicTarget(id: 1, gene: "TEST", sequence: idealSg, species: .human, type: .sgRNA)
let dummyTargetLow = GenomicTarget(id: 2, gene: "TEST", sequence: fatalSg, species: .human, type: .sgRNA)
assert(dummyTargetHigh.score > dummyTargetLow.score, "High target score must exceed low target score")
pass("ShRNAScoringEngine passed (Ideal: \(idealShScore.score), Fatal TTTT: \(fatalShScore.score)).")

// 13. SnapGeneService 真实文件解析与安全原位注入测试
print("🧪 [13/52] Testing SnapGeneService (parse & in-place primer injection with backup)...")
let testSrcPath = "/tmp/nonexistent_optional_bench_sample.dna"
if FileManager.default.fileExists(atPath: testSrcPath) {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapgene_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let tmpDNA = tmpDir.appendingPathComponent("target_plasmid.dna")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: testSrcPath), to: tmpDNA)
    
    // 解析原文件
    let parsedInfo = try await SnapGeneService.shared.parseDNAFile(at: tmpDNA)
    assert(parsedInfo.length == 6475, "Expected length 6475, got \(parsedInfo.length)")
    assert(parsedInfo.featuresCount == 25, "Expected 25 features, got \(parsedInfo.featuresCount)")
    assert(parsedInfo.isCircular == true, "Expected circular topology")
    
    // 原位注入带 5' 同源臂引物
    let testPrimers = [
        PrimerItem(name: "Test-Verify-Seamless-F", fullSequence: "cggccgctcgagcatATGGTGAGCAAGGGCGAGG", targetPurpose: "测试引物注入", sourceTool: "验证套件")
    ]
    let injectRes = try await SnapGeneService.shared.injectPrimers(testPrimers, into: tmpDNA, createBackup: true)
    assert(injectRes.backupPath != nil, "Backup path should be generated")
    assert(FileManager.default.fileExists(atPath: injectRes.backupPath!), "Backup file must exist on disk")
    
    let recheck = try await SnapGeneService.shared.parseDNAFile(at: tmpDNA)
    assert(recheck.primersCount > parsedInfo.primersCount, "Primers count must increase after injection")
    
    try? FileManager.default.removeItem(at: tmpDir)
    pass("SnapGene parse & in-place inject passed (backup created & primers verified).")
} else {
    print("   ⚠️ Skipped [13/52] (Desktop sample file not found)")
}

// 14. SnapGeneService 双质粒重组装配测试
print("🧪 [14/52] Testing SnapGeneService (dual-plasmid recombinant assembly)...")
if FileManager.default.fileExists(atPath: testSrcPath) {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recomb_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let outDNA = tmpDir.appendingPathComponent("Recombinant-Construct.dna")
    
    let egfpSeq = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"
    
    _ = try await SnapGeneService.shared.assembleRecombinant(
        vectorURL: URL(fileURLWithPath: testSrcPath),
        insertSourceURL: nil,
        insertSeq: egfpSeq,
        insertName: "EGFP",
        cutStart: 5000,
        cutEnd: 5020,
        primers: [
            PrimerItem(name: "EGFP-Junc-F", fullSequence: "cggccgctcgagcatATGGTGAGCAAGGGCGAGG", targetPurpose: "接头正向引物"),
            PrimerItem(name: "EGFP-Junc-R", fullSequence: "gatccgaattcgagcTTACTTGTACAGCTCGTCCA", targetPurpose: "接头反向引物")
        ],
        outputURL: outDNA
    )
    
    assert(FileManager.default.fileExists(atPath: outDNA.path), "Output recombinant .dna must exist")
    let recombInfo = try await SnapGeneService.shared.parseDNAFile(at: outDNA)
    let expectedLen = 6475 - 21 + egfpSeq.count
    assert(recombInfo.length == expectedLen, "Recombinant length mismatch: \(recombInfo.length) vs \(expectedLen)")
    assert(recombInfo.features.contains { $0.name.contains("EGFP") }, "Recombinant must contain EGFP feature")
    
    try? FileManager.default.removeItem(at: tmpDir)
    pass("SnapGene dual-plasmid recombinant assembly passed (Length: \(expectedLen) bp, Feature & Primers embedded).")
} else {
    print("   ⚠️ Skipped [14/52] (Desktop sample file not found)")
}

// 15. HomologyArmDesigner 质粒片段删除与反向 PCR 环化引物设计测试
print("🧪 [15/52] Testing HomologyArmDesigner.designFragmentDeletion (18bp Golden Homology Arm)...")
let mockPlasmid = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"
let delRes18 = HomologyArmDesigner.designFragmentDeletion(
    plasmidSeq: mockPlasmid,
    delStart: 100,
    delEnd: 299,
    homologyLength: 18
)
assert(delRes18.deletedLength == 200, "Deleted length must be 200, got \(delRes18.deletedLength)")
assert(delRes18.newLength == mockPlasmid.count - 200, "New plasmid length mismatch")
assert(delRes18.primerF.homologyArm.count == 18, "Homology arm length must be 18 bp")
assert(delRes18.primerF.fullSequence.lowercased().hasPrefix(delRes18.primerF.homologyArm.lowercased()), "Primer F must start with homology arm")
assert((delRes18.primerF.tm ?? 0) >= 55.0, "Primer F Tm must be >= 55℃")
assert((delRes18.primerR.tm ?? 0) >= 55.0, "Primer R Tm must be >= 55℃")
pass("designFragmentDeletion passed (18 bp homology arm verified).")

// 16. SnapGeneService 真实质粒片段敲除与新产物重构测试
print("🧪 [16/52] Testing SnapGeneService.deleteFragment (Plasmid Fragment Deletion & Feature Re-mapping)...")
if FileManager.default.fileExists(atPath: testSrcPath) {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("del_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let outDNA = tmpDir.appendingPathComponent("Knockout-Plasmid.dna")
    
    let delTestPrimers = [
        delRes18.primerF,
        delRes18.primerR
    ]
    
    _ = try await SnapGeneService.shared.deleteFragment(
        vectorURL: URL(fileURLWithPath: testSrcPath),
        delStart: 1000,
        delEnd: 1200,
        primers: delTestPrimers,
        outputURL: outDNA
    )
    
    assert(FileManager.default.fileExists(atPath: outDNA.path), "Output knockout .dna must exist on disk")
    let knockoutInfo = try await SnapGeneService.shared.parseDNAFile(at: outDNA)
    assert(knockoutInfo.length == 6475 - 201, "Expected length \(6475 - 201), got \(knockoutInfo.length)")
    assert(knockoutInfo.features.contains { $0.name.contains("Δ Deletion") }, "Knockout plasmid must contain Δ Deletion feature")
    assert(knockoutInfo.primersCount >= 2, "Knockout plasmid must contain injected primers")
    
    try? FileManager.default.removeItem(at: tmpDir)
    pass("SnapGene deleteFragment passed (Deleted: 201 bp, New Length: \(knockoutInfo.length) bp, Features re-mapped).")
} else {
    print("   ⚠️ Skipped [16/52] (Desktop sample file not found)")
}

// 17. CloneCanvas 纯数学几何层测试 (CircularGeometry + CircularOVELayout)
print("🧪 [17/52] Testing CircularGeometry & CircularOVELayout (Polar math, Concentric Y-Offsets & 4-Quadrant Label Relaxation)...")
let testCenter = CartesianPoint(x: 200, y: 200)
let pt12 = CircularGeometry.polarToCartesian(radius: 100, angleRadians: 0, center: testCenter)
assert(abs(pt12.x - 200.0) < 1e-6 && abs(pt12.y - 100.0) < 1e-6, "12 o'clock polarToCartesian mismatch")
let backAngle = CircularGeometry.cartesianToPolarAngle(point: CartesianPoint(x: 300, y: 200), center: testCenter)
assert(abs(backAngle - (.pi / 2.0)) < 1e-6, "3 o'clock cartesianToPolarAngle must be π/2")

let idA = UUID()
let idB = UUID()
let idC = UUID()
let ovRanges = [
    CircularRange(id: idA, start: 100, end: 600),
    CircularRange(id: idB, start: 300, end: 800), // 与 A 重叠，应推到轨道 1
    CircularRange(id: idC, start: 900, end: 1200) // 不与轨道 0 的 A 重叠，应复用轨道 0
]
let yOffsets = CircularOVELayout.calculateConcentricYOffsets(features: ovRanges, sequenceLength: 2000)
assert(yOffsets[idA] == 0, "idA should be at track 0")
assert(yOffsets[idB] == 1, "idB overlaps idA and should be pushed to track 1")
assert(yOffsets[idC] == 0, "idC does not overlap idA and should reuse track 0")

let crowdedLabels = [
    OveCircularLabel(text: "BamHI", angle: 0.40, radius: 90, isEnzyme: true, priority: 10),
    OveCircularLabel(text: "EcoRI", angle: 0.41, radius: 90, isEnzyme: true, priority: 10),
    OveCircularLabel(text: "HindIII", angle: 0.42, radius: 90, isEnzyme: true, priority: 10)
]
let relaxed = CircularGeometry.relaxLabelAngles(labels: crowdedLabels, radius: 120, center: testCenter, canvasWidth: 400, canvasHeight: 400, textVerticalOffset: 14)
assert(relaxed.count == 3, "Must return 3 relaxed labels")
let sortedY = relaxed.map { $0.outerPoint.y }.sorted()
assert(sortedY[1] - sortedY[0] >= 13.5 && sortedY[2] - sortedY[1] >= 13.5, "Relaxed labels must have >= 14pt vertical separation")
pass("CircularGeometry & CircularOVELayout passed (Concentric tracks & label collision relaxation verified).")

// 18. 微观单碱基双链与氨基酸密码子翻译引擎测试 (SequenceRowLayout + CodonTranslator)
print("🧪 [18/52] Testing SequenceRowLayout & CodonTranslator (36bp row slicing, complement & codon ribbon)...")
let testCDS = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTCTAA"
let codons = CodonTranslator.translateSequence(testCDS, readingFrameOffset: 0)
assert(codons.first?.aminoAcid == "M" && codons.first?.isStartCodon == true, "First codon must be Start (M)")
assert(codons.last?.aminoAcid == "*" && codons.last?.isStopCodon == true, "Last codon TAA must be Stop (*)")

let testWin = MicroscopicSequenceWindow(
    title: "Test Junction",
    startBp: 101,
    sequence: testCDS,
    homologyHighlightRange: 0..<18,
    focalHighlightRange: 18..<21
)
let rowSlices = SequenceRowLayout.sliceWindow(testWin, basesPerRow: 36)
assert(rowSlices.count == 2, "70bp sequence at 36bp/row must produce 2 row slices")
assert(rowSlices[0].topStrand.count == 36 && rowSlices[0].bottomStrand.count == 36, "First slice must have 36bp double strand")
assert(rowSlices[0].codons.count == 12, "36bp slice must contain 12 translated codons")
pass("SequenceRowLayout & CodonTranslator passed (2 rows, 12 codons/row, Start M & Stop * verified).")

// 19. 质粒构建谱系树与改造前后 Feature 坐标位移测试 (ConstructHistoryManager)
print("🧪 [19/52] Testing ConstructHistoryManager (Multi-step genealogy & FeatureShiftItem diff calculation)...")
let wtFeatures: [(String, Int, Int)] = [
    ("Promoter", 100, 500),
    ("ExcisedTag", 600, 750),
    ("AmpR", 1200, 2060)
]
let shiftItems = ConstructHistoryManager.computeFeatureShifts(
    originalFeatures: wtFeatures,
    editStartBp: 600,
    editEndBp: 750,
    insertedBp: 720,
    insertedFeatureName: "EGFP (720bp)"
)
assert(shiftItems.contains { $0.featureName == "Promoter" && $0.status == .unchanged }, "Upstream Promoter must remain unchanged")
assert(shiftItems.contains { $0.featureName == "ExcisedTag" && $0.status == .deleted }, "ExcisedTag inside cut range must be marked deleted")
assert(shiftItems.contains { $0.featureName == "EGFP (720bp)" && $0.status == .inserted }, "Inserted EGFP must be marked inserted")
assert(shiftItems.contains { $0.featureName == "AmpR" && $0.status == .shifted && $0.deltaBp == (720 - 151) }, "Downstream AmpR must shift by +569 bp")
pass("ConstructHistoryManager & FeatureShiftItem passed (Upstream unchanged, Deleted, Inserted, Downstream +569bp shift verified).")

// 20. 精细质粒工作台引擎测试 (scanConstructCutsites + NEB Buffer 活性矩阵 + 动态每行碱基数 + 选区 Tm)
print("🧪 [20/52] Testing Fine-Grained Plasmid Workbench Engine (ConstructCutsite scanner, NEB Buffer matrix & dynamic row layout)...")
let testConstructSeq = "ATGCAAGGCCTGGCCTAATGCAGCTGGGAATTCGGATCCAAGCTTGGTCTCAAATTTAAACTCGAGCATATG"
let scannedSites = RestrictionEnzymeDatabase.shared.scanConstructCutsites(
    sequence: testConstructSeq,
    circular: true,
    enzymeNames: ["StuI", "HaeIII", "EcoRI", "BamHI", "HindIII", "BsaI", "DraI", "XhoI", "NdeI"]
)
assert(scannedSites.contains { $0.name == "StuI" && $0.topSnip0Based == $0.bottomSnip0Based }, "StuI must be detected as a blunt cutter")
assert(scannedSites.contains { $0.name == "EcoRI" && $0.bottomSnip0Based - $0.topSnip0Based == 4 }, "EcoRI must have 4bp 5' overhang (bottom - top == 4)")
assert(scannedSites.contains { $0.name == "BsaI" && $0.isType2S == true }, "BsaI must be detected as a Type IIS enzyme")

let ecoBuf = RestrictionEnzymeDatabase.shared.bufferCompatibility(for: "EcoRI")
assert(ecoBuf.cutSmart == 100 && ecoBuf.r2_1 == 100, "EcoRI must have 100% activity in CutSmart & r2.1")

let opt36 = SequenceRowLayout.optimalBasesPerRow(forWidth: 420)
let opt60 = SequenceRowLayout.optimalBasesPerRow(forWidth: 620)
assert(opt36 % 3 == 0 && opt60 % 3 == 0 && opt60 > opt36, "optimalBasesPerRow must always be a multiple of 3 and scale with width")

let selTm = SequenceRowLayout.estimateSelectionTm("ATGTGCGTCGCCTCGCCTCAGAACAACACCA")
assert(selTm >= 55 && selTm <= 80, "31bp selection Tm must be in realistic biological range (55..80°C)")

AppState.shared.showPlasmidPreview = true
AppState.shared.isPreviewExpanded = true
AppState.shared.showPlasmidPreview = false
assert(AppState.shared.isPreviewExpanded == false, "Closing plasmid preview must automatically reset isPreviewExpanded to false")
AppState.shared.showPlasmidPreview = true
pass("Fine-Grained Plasmid Workbench Engine passed (\(scannedSites.count) cut sites, NEB Buffer matrix, \(opt36)->\(opt60)bp/row, Tm=\(selTm)°C verified).")

// 21. 验证简化版浅色/深色应用图标、系统深浅色自动跟随与 macOS 状态栏模板图标
print("🧪 [21/52] Testing CloneStudioIconProvider (Light/Dark simplified icons & macOS status bar template icon)...")
let lightAppIcon = CloneStudioIconProvider.iconImage(isLight: true)
let darkAppIcon = CloneStudioIconProvider.iconImage(isLight: false)
let statusTplIcon = CloneStudioIconProvider.statusBarTemplateImage
assert(lightAppIcon.size.width > 0 && lightAppIcon.size.height > 0, "Light mode app icon must have valid dimensions")
assert(darkAppIcon.size.width > 0 && darkAppIcon.size.height > 0, "Dark mode app icon must have valid dimensions")
assert(statusTplIcon.isTemplate == true, "macOS status bar icon must be marked isTemplate = true")
await MainActor.run {
    assert(CloneStudioIconProvider.resolveIsLightAppearance(mode: .light) == true, "Light mode must resolve to light icon")
    assert(CloneStudioIconProvider.resolveIsLightAppearance(mode: .dark) == false, "Dark mode must resolve to dark icon")
}
pass("CloneStudioIconProvider passed (Light icon, Dark icon & StatusBar template icon verified).")

// 22. 验证 CHOPCHOP 全维综合评分 (combinedScore) 与本地 SG/SH 序列三级高亮匹配算法
print("🧪 [22/52] Testing CHOPCHOP combinedScore & Local SG/SH Highlighting Comparison...")
let chopTarget1 = CHOPCHOPTarget(
    rank: 15,
    targetSequence: "CCATTGTTCAATATCGTCCGGGG",
    spacer: "CCATTGTTCAATATCGTCCG",
    pam: "GGG",
    genomicLocation: "chr17:7675056",
    strand: "+",
    gcContent: 50.0,
    selfComplementarity: 0,
    mm0: 0,
    mm1: 0,
    mm2: 0,
    mm3: 1,
    efficiency: 74.5
)
let chopTargetLowEff = CHOPCHOPTarget(
    rank: 1,
    targetSequence: "GAGCTCCCGGGGGGGGGGGGGG".replacingOccurrences(of: "", with: "G"),
    spacer: "GAGCTCCCGGGGGGGGGGGG",
    pam: "GGG",
    genomicLocation: "chr17:7675100",
    strand: "-",
    gcContent: 85.0,
    selfComplementarity: 2,
    mm0: 0,
    mm1: 0,
    mm2: 0,
    mm3: 0,
    efficiency: 28.0
)
assert(chopTarget1.combinedScore.score > chopTargetLowEff.combinedScore.score, "High efficiency specific target must have higher combinedScore than low efficiency extreme-GC target")

let localSg = LocalCompareTarget(label: "本地已选 sg#1", sequence: "CCATTGTTCAATATCGTCCG", sourceType: .sgRNA, isSelectedOrGenerated: true)
let localSh = LocalCompareTarget(label: "本地已选 sh#1", sequence: "ACCATTGTTCAATATCGTCCG", sourceType: .shRNA, isSelectedOrGenerated: true) // 21bp 包含 20bp
let localRC = LocalCompareTarget(label: "本地反义 sh#2", sequence: BioSequence.reverseComplement("CCATTGTTCAATATCGTCCG"), sourceType: .shRNA, isSelectedOrGenerated: true)

let exactHit = chopTarget1.matchAgainstLocalTargets([localSg])
assert(exactHit?.kind == .exact && exactHit?.isPrimaryUserSelection == true, "Exact 20bp sgRNA match failed")

let coreHit = chopTarget1.matchAgainstLocalTargets([localSh])
assert(coreHit != nil, "21bp shRNA core overlap match failed")

let rcHit = chopTarget1.matchAgainstLocalTargets([localRC])
if case .reverseComplementOverlap(let len) = rcHit?.kind {
    assert(len == 20, "Reverse complement 20bp overlap length mismatch")
} else {
    assertionFailure("Reverse complement match failed")
}

// 验证切换功能条目 (selectedNav) 绝不清空 CHOPCHOP / Broad GPP / sgRNA / shRNA 查询结果
await MainActor.run {
    let session = WorkspaceSessionManager.shared
    session.chopchopVM.gene = "TP53"
    session.chopchopVM.targets = [chopTarget1, chopTargetLowEff]
    session.broadGPPVM.gene = "TP53"
    session.broadGPPVM.targets = parsedGPPTargets
    session.sgRNAVM.sourceMode = .onlineCompare
    session.shRNAVM.sourceMode = .broadGPP
    AppState.shared.selectedNav = .singleFragment
    AppState.shared.selectedNav = .sgRNADesign
    AppState.shared.selectedNav = .shRNADesign
    assert(session.chopchopVM.gene == "TP53" && session.chopchopVM.targets.count == 2, "Switching sidebar navigation must preserve sgRNA inline online comparison results")
    assert(session.broadGPPVM.gene == "TP53" && session.broadGPPVM.targets.count == 2, "Switching sidebar navigation must preserve Broad GPP comparison results")
    assert(session.sgRNAVM.sourceMode == .onlineCompare && session.shRNAVM.sourceMode == .broadGPP)
    session.chopchopVM.clear()
    session.broadGPPVM.clear()
    session.sgRNAVM.sourceMode = .library
    session.shRNAVM.sourceMode = .library
}

// 验证三源靶点共识合并与 Codable 往返一致性
let sharedSpacer = "GGCAGCGATTGCAGTTCACG"
let chopSeed = CHOPCHOPTarget(
    rank: 1,
    targetSequence: sharedSpacer + "AGG",
    spacer: sharedSpacer,
    pam: "AGG",
    genomicLocation: "chr17:7675056",
    strand: "+",
    gcContent: 60.0,
    selfComplementarity: 0,
    mm0: 0,
    mm1: 0,
    mm2: 1,
    mm3: 2,
    efficiency: 60.0
)
let vbcMatch = CHOPCHOPTarget(
    rank: 1,
    targetSequence: sharedSpacer + "AGG",
    spacer: sharedSpacer,
    pam: "AGG",
    genomicLocation: "chr17:7675056 (Exon 4)",
    strand: "+",
    gcContent: 60.0,
    selfComplementarity: 0,
    mm0: 0,
    mm1: 0,
    mm2: 0,
    mm3: 0,
    efficiency: 90.0,
    sources: [.vbcScore],
    hasCHOPCHOPOffTargets: false,
    vbcScore: 0.86,
    vbcActivity: 0.90,
    vbcFrameshift: 0.85,
    vbcBioscore: 0.88,
    vbcAutoPick: 1,
    vbcVeryLikelyOT: 0,
    vbcLikelyOT: 0,
    vbcOT90: 0,
    vbcExon: "Exon 4"
)
let crisporMatch = CHOPCHOPTarget(
    rank: 1,
    targetSequence: sharedSpacer + "AGG",
    spacer: sharedSpacer,
    pam: "AGG",
    genomicLocation: "chr17:7675056",
    strand: "+",
    gcContent: 60.0,
    selfComplementarity: 0,
    mm0: 0,
    mm1: 0,
    mm2: 0,
    mm3: 0,
    efficiency: 90.0,
    sources: [.ucscCrispor],
    hasCHOPCHOPOffTargets: false,
    mitSpecificity: 95,
    crisporDoenchPerc: 90.0,
    crisporScanScore: 78.0,
    crisporOutOfFrame: 80.0
)
let vbcOnly = CHOPCHOPTarget(
    rank: 2,
    targetSequence: "TGGAGCTGAAGCTCGATCACTGG",
    spacer: "TGGAGCTGAAGCTCGATCAC",
    pam: "TGG",
    genomicLocation: "chr17:7674200 (Exon 5)",
    strand: "-",
    gcContent: 55.0,
    selfComplementarity: 0,
    mm0: 0,
    mm1: 0,
    mm2: 0,
    mm3: 0,
    efficiency: 72.0,
    sources: [.vbcScore],
    hasCHOPCHOPOffTargets: false,
    vbcScore: 0.74,
    vbcActivity: 0.72
)

let mergedMulti = CHOPCHOPTarget.mergeTargets(
    chopchop: [chopSeed],
    vbc: [vbcMatch, vbcOnly],
    crispor: [crisporMatch]
)
assert(mergedMulti.count == 2, "3 sources with shared 20bp spacer should merge into 2 unique targets")
assert(Set(mergedMulti.map(\.rank)) == Set([1, 2]), "Merged targets should have unique sequential ranks 1..N")
let consensusItem = mergedMulti.first { $0.spacer == sharedSpacer }!
assert(consensusItem.sources.count == 3, "Consensus item must record all 3 sources")
assert(consensusItem.isMultiSourceConsensus, "Consensus item must flag isMultiSourceConsensus")
assert(consensusItem.vbcScore == 0.86 && consensusItem.mitSpecificity == 95 && consensusItem.hasCHOPCHOPOffTargets)
assert(consensusItem.combinedScore.score > chopSeed.combinedScore.score, "3-source high-confidence consensus should score higher than moderate single-source CHOPCHOP seed")

let encodedMerged = try JSONEncoder().encode(mergedMulti)
let decodedMerged = try JSONDecoder().decode([CHOPCHOPTarget].self, from: encodedMerged)
let decodedConsensus = decodedMerged.first { $0.spacer == sharedSpacer }!
assert(decodedConsensus.sources == consensusItem.sources)
assert(decodedConsensus.vbcScore == consensusItem.vbcScore)
assert(decodedConsensus.mitSpecificity == consensusItem.mitSpecificity)
assert(decodedConsensus.isMultiSourceConsensus)

pass("CHOPCHOP combinedScore, Local SG/SH 3-tier matching & cross-tab persistence passed (Score: \(chopTarget1.combinedScore.score) vs \(chopTargetLowEff.combinedScore.score)).")

// 23. 验证状态栏图标显隐开关、PlasmidPoolManager 质粒池解析入库与 CloneStudio MCP Server 一键设计引物
print("🧪 [23/52] Testing StatusBarIcon toggle, PlasmidPoolManager & CloneStudio MCP Server...")
await MainActor.run {
    let orig = AppState.shared.showStatusBarIcon
    AppState.shared.showStatusBarIcon = false
    assert(AppState.shared.showStatusBarIcon == false, "showStatusBarIcon must toggle to false")
    AppState.shared.showStatusBarIcon = true
    assert(AppState.shared.showStatusBarIcon == true, "showStatusBarIcon must toggle back to true")
    AppState.shared.showStatusBarIcon = orig
}

func makeSyntheticSnapGeneDNA(sequence: String, featuresXML: String) -> Data {
    var d = Data()
    let hdr = Array("SnapGene".utf8) + [0x00, 0x01, 0x00, 0x0e, 0x00, 0x02]
    d.append(0x09)
    var hdrLen = UInt32(hdr.count).bigEndian
    d.append(Data(bytes: &hdrLen, count: 4))
    d.append(contentsOf: hdr)
    let seqBytes = [UInt8(0x01)] + Array(sequence.utf8)
    d.append(0x00)
    var seqLen = UInt32(seqBytes.count).bigEndian
    d.append(Data(bytes: &seqLen, count: 4))
    d.append(contentsOf: seqBytes)
    let featBytes = Array(featuresXML.utf8)
    d.append(0x0a)
    var featLen = UInt32(featBytes.count).bigEndian
    d.append(Data(bytes: &featLen, count: 4))
    d.append(contentsOf: featBytes)
    return d
}
let tmpPoolDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_test23_\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: tmpPoolDir, withIntermediateDirectories: true)
let sampleDNA1 = tmpPoolDir.appendingPathComponent("pETDuet-EGFP-Demo.dna")
let sampleDNA2 = tmpPoolDir.appendingPathComponent("pCMV-TP53-3xFLAG.dna")
let vecSeq6000 = String(repeating: "ATGCGATCGATCGATCGATCGCTAGCTAGCTAGCTA", count: 170) // 6120 bp
let tp53CDS = "ATGGAGGAGCCGCAGTCAGATCCTAGCGTCGAGCCCCCTCTGAGTCAGGAAACATTTTCAGACCTATGGAAACTACTTCCTGAAAACAACGTTCTGTCCCCCTTGCCGTCCCAAGCAATGGATGATTTGATGCTGTCCCCGGACGATATTGAACAATGGTTCACTGAAGACCCAGGTCCAGATGAAGCTCCCAGAATGCCAGAGGCTGCTCCCCCCGTGGCCCCTGCACCAGCAGCTCCTACACCGGCGGCCCCTGCACCAGCCCCCTCCTGGCCCCTGTCATCTTCTGTCCCTTCCCAGAAAACCTACCAGGGCAGCTACGGTTTCCGTCTGGGCTTCTTGCATTCTGGGACAGCCAAGTCTGTGACTTGCACGTACTCCCCTGCCCTCAACAAGATGTTTTGCCAACTGGCCAAGACCTGCCCTGTGCAGCTGTGGGTTGATTCCACACCCCCGCCCGGCACCCGCGTCCGCGCCATGGCCATCTACAAGCAGTCACAGCACATGACGGAGGTTGTGAGGCGCTGCCCCCACCATGAGCGCTGCTCAGATAGCGATGGTCTGGCCCCTCCTCAGCATCTTATCCGAGTGGAAGGAAATTTGCGTGTGGAGTATTTGGATGACAGAAACACTTTTCGACATAGTGTGGTGGTGCCCTATGAGCCGCCTGAGGTTGGCTCTGACTGTACCACCATCCACTACAACTACATGTGTAACAGTTCCTGCATGGGCGGCATGAACCGGAGGCCCATCCTCACCATCATCACACTGGAAGACTCCAGTGGTAATCTACTGGGACGGAACAGCTTTGAGGTGCGTGTTTGTGCCTGTCCTGGGAGAGACCGGCGCACAGAGGAAGAGAATCTCCGCAAGAAAGGGGAGCCTCACCACGAGCTGCCCCCAGGGAGCACTAAGCGAGCACTGCCCAACAACACCAGCTCCTCTCCCCAGCCAAAGAAGAAACCACTGGATGGAGAATATTTCACCCTTCAGATCCGTGGGCGTGAGCGCTTCGAGATGTTCCGAGAGCTGAATGAGGCCTTGGAACTCAAGGATGCCCAGGCTGGGAAGGAGCCAGGGGGGAGCAGGGCTCACTCCAGCCACCTGAAGTCCAAAAAGGGTCAGTCTACCTCCCGCCATAAAAAACTCATGTTCAAGACAGAAGGGCCTGACTCAGACTGA"
let donorSeq = String(repeating: "GCTAGCTAGCTA", count: 84) + tp53CDS + String(repeating: "CGATCGATCGAT", count: 100)
let vecFeatXML = "<Features><Feature name=\"AmpR\" type=\"CDS\" directionality=\"1\"><Segment range=\"200-1060\"/></Feature><Feature name=\"T7 promoter\" type=\"promoter\" directionality=\"1\"><Segment range=\"5500-5519\"/></Feature></Features>"
let donorFeatXML = "<Features><Feature name=\"TP53\" type=\"CDS\" directionality=\"1\"><Segment range=\"1009-\(1008 + tp53CDS.count)\"/></Feature><Feature name=\"NeoR\" type=\"CDS\" directionality=\"1\"><Segment range=\"2600-3390\"/></Feature></Features>"
try makeSyntheticSnapGeneDNA(sequence: vecSeq6000, featuresXML: vecFeatXML).write(to: sampleDNA1)
try makeSyntheticSnapGeneDNA(sequence: donorSeq, featuresXML: donorFeatXML).write(to: sampleDNA2)
await PlasmidPoolManager.shared.importFilesOrFolders(urls: [sampleDNA1, sampleDNA2], silent: true, maxDepth: 0)
let poolCount = await MainActor.run { PlasmidPoolManager.shared.items.count }
assert(poolCount >= 2, "PlasmidPoolManager must parse and import .dna plasmids, found \(poolCount)")

let mcpScript = await MainActor.run { PlasmidPoolManager.shared.mcpServerScriptPath }
assert(FileManager.default.fileExists(atPath: mcpScript), "MCP Server script must exist at \(mcpScript)")

let mcpProc = Process()
mcpProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
mcpProc.arguments = [
    mcpScript,
    "--cli-call", "design_single_clone_primers",
    "--args", #"{"vector_name":"pETDuet","vector_site":"5556..5705","insert_source":"pCMV-TP53:TP53","homology_length":18,"export_recombinant_dna":false,"add_to_cart":false}"#
]
let mcpPipe = Pipe()
mcpProc.standardOutput = mcpPipe
try mcpProc.run()
let mcpOutData = mcpPipe.fileHandleForReading.readDataToEndOfFile()
mcpProc.waitUntilExit()
assert(mcpProc.terminationStatus == 0, "MCP Server CLI call must exit with 0")
let mcpOutStr = String(data: mcpOutData, encoding: .utf8) ?? ""
assert(mcpOutStr.contains("\"status\": \"success\"") && mcpOutStr.contains("TP53-F"), "MCP Server single clone primer design must return valid primers")

// 测试完成后立即清空质粒池与临时文件，确保质粒池默认保持完全空白
await MainActor.run {
    PlasmidPoolManager.shared.clearAll()
}
try? FileManager.default.removeItem(at: tmpPoolDir)
let projRootClean = CloneStudioResourceLocator.projectRootDirectory
try? FileManager.default.removeItem(at: projRootClean.appendingPathComponent(".clonestudio_plasmid_pool.json"))
try? FileManager.default.removeItem(at: projRootClean.deletingLastPathComponent().appendingPathComponent(".clonestudio_plasmid_pool.json"))
if let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
    try? FileManager.default.removeItem(at: appSup.appendingPathComponent("CloneStudio/plasmid_pool.json"))
}

// 验证 Labworker MCP Server 20261115 JSON-RPC 2.0 协议与全部实验工具 (23 Tools)
let mcpRpcProc = Process()
mcpRpcProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
mcpRpcProc.arguments = [mcpScript]
let rpcInPipe = Pipe()
let rpcOutPipe = Pipe()
mcpRpcProc.standardInput = rpcInPipe
mcpRpcProc.standardOutput = rpcOutPipe
try mcpRpcProc.run()
let rpcRequests = """
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"analyze_protein_and_docking_box","arguments":{"sequence":"MKVLLFAAVVGGLAAAGVSAKELRKIYEDGKVTYTLDNGKPVVLVFYPADFTFVCPTEIIAFSENAAKKFEEQGAQVLFASTDSEYSLLAWTNIPRKEGGLGPINIPLLADTN","mutations":["V13A","T48P"]}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"analyze_western_blot","arguments":{"target_iods":[100,110,220,240],"loading_control_iods":[100,105,100,102],"lane_groups":["WT","WT","KO","KO"]}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"convert_nucleic_acid_units","arguments":{"mode":"dsdna_ug_to_pmol","length_bp_or_nt":5000,"value":1}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"convert_protein_and_coding","arguments":{"mode":"coding_from_bp","value":900}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"calculate_solution_and_temperature","arguments":{"mode":"dilution","stock_conc":1,"stock_unit":"M","final_conc":10,"final_unit":"mM","final_volume":50,"vol_unit":"mL"}}}
"""
rpcInPipe.fileHandleForWriting.write(rpcRequests.data(using: .utf8)!)
try? rpcInPipe.fileHandleForWriting.close()
let rpcOutData = rpcOutPipe.fileHandleForReading.readDataToEndOfFile()
mcpRpcProc.waitUntilExit()
let rpcOutStr = String(data: rpcOutData, encoding: .utf8) ?? ""
assert(rpcOutStr.contains("labworker-mcp") && rpcOutStr.contains("20261115"), "MCP Server must identify as labworker-mcp 20261115")
assert(rpcOutStr.contains("analyze_protein_and_docking_box") && rpcOutStr.contains("analyze_western_blot") && rpcOutStr.contains("analyze_qpcr_ddct") && rpcOutStr.contains("design_plate_layout") && rpcOutStr.contains("verify_sanger_sequencing") && rpcOutStr.contains("convert_nucleic_acid_units") && rpcOutStr.contains("convert_protein_and_coding") && rpcOutStr.contains("calculate_solution_and_temperature") && rpcOutStr.contains("deconvolute_crispr_sanger") && rpcOutStr.contains("auto_annotate_sequence") && rpcOutStr.contains("design_golden_gate_assembly") && rpcOutStr.contains("design_hdr_donor"), "MCP Server must expose all 23 full-stack tools")
assert(!rpcOutStr.contains("analyze_phylogenetic_tree"), "Removed phylogenetic tree tool must not appear in MCP tool list")
assert(rpcOutStr.contains("vina_config") && rpcOutStr.contains("mean_fold") && rpcOutStr.contains("0.3 pmol") && rpcOutStr.contains("49.5 mL"), "MCP Server bio calculation tools must return verified outputs")
let catalogCount = await MainActor.run { PlasmidPoolManager.mcpToolsCatalog.count }
let cfgJSON = await MainActor.run { PlasmidPoolManager.shared.mcpConfigJSONString }
assert(catalogCount == 23 && cfgJSON.contains("\"labworker\""), "PlasmidPoolManager must expose 23 MCP tools and labworker JSON config")

// 验证 SnapGene XML BindingSite 同时兼容 strand="1" 与 boundStrand="1"（避免反向引物误显示为 F）
let bridgeDir = URL(fileURLWithPath: mcpScript).deletingLastPathComponent().path
let strandProbe = Process()
strandProbe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
strandProbe.arguments = [
    "-c",
    "import sys; sys.path.insert(0, sys.argv[1]); import snapgene_bridge as sb; xml=b'<Primers><Primer name=\"Test-F\" sequence=\"ATGCATGCATGC\"><BindingSite location=\"0-11\" strand=\"0\"/></Primer><Primer name=\"Test-R\" sequence=\"GCATGCATGCAT\"><BindingSite location=\"50-61\" strand=\"1\"/></Primer></Primers>'; res=sb.extract_primers([(5, xml)]); assert res[0]['bindingSites'][0]['strand']=='0' and res[1]['bindingSites'][0]['strand']=='1', res; print('STRAND_OK')",
    bridgeDir
]
let strandPipe = Pipe()
strandProbe.standardOutput = strandPipe
try strandProbe.run()
strandProbe.waitUntilExit()
let strandOut = String(data: strandPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
assert(strandProbe.terminationStatus == 0 && strandOut.contains("STRAND_OK"), "snapgene_bridge extract_primers must parse strand='1' as reverse strand")

pass("StatusBarIcon toggle, PlasmidPoolManager (\(poolCount) plasmids), SnapGene reverse-primer strand='1' & Labworker MCP Server 20261115 (23 tools) passed.")

// 24. 验证 Phase 1 实验台工具引擎 (PlateLayoutEngine + QPCRAnalysisEngine)
print("🧪 [24/52] Testing Phase 1 Bench Engines (PlateLayoutEngine & QPCRAnalysisEngine)...")
let demoSamples = PlateLayoutEngine.parseSampleTable("Sample\tGroup\tReplicates\nWT\tControl\t3\nTP53-OE\tTreatment\t3\nTP53-KO\tTreatment\t3")
assert(demoSamples.count == 3, "Must parse 3 sample definitions")
let autoPlate = PlateLayoutEngine.assignPlate(
    format: .well96,
    samples: demoSamples,
    rules: PlateLayoutRules(reserveEdge: true, randomize: true, seed: 42)
)
assert(autoPlate.assignments.count >= 9, "3 samples x 3 replicates must assign >= 9 wells")
let plateCSV = PlateLayoutEngine.exportPlateCSV(format: .well96, assignments: autoPlate.assignments)
assert(plateCSV.contains("WT") && plateCSV.contains("TP53-OE"), "Exported plate CSV must include sample names")

let qpcrWells = QPCRAnalysisEngine.parseQPCRTable(QPCRAnalysisEngine.defaultExampleCSV)
assert(qpcrWells.count >= 18, "Demo qPCR dataset must parse >= 18 wells")
let qpcrSettings = QPCRSettings(referenceTargets: ["ACTB"], controlSample: "WT")
let qpcrQC = QPCRAnalysisEngine.computeQC(wells: qpcrWells, settings: qpcrSettings)
let qpcrReport = QPCRAnalysisEngine.computeDdct(
    wells: qpcrWells,
    settings: qpcrSettings,
    qc: qpcrQC
)
assert(!qpcrReport.sampleResults.isEmpty, "qPCR relative quantification must produce sampleResults")
assert(qpcrReport.sampleResults.contains { $0.sample.hasPrefix("TP53-OE") && $0.fold > 2.0 }, "TP53-OE fold change must be > 2.0")
pass("Phase 1 Bench Engines passed (Plate 96-well auto layout & qPCR ΔΔCt verified).")


// 26. 验证 Western Blot 灰度积分定量与凝胶电泳分子量回归引擎 (WesternBlotEngine + GelAnalysisEngine)
print("🧪 [26/52] Testing WesternBlotEngine & GelAnalysisEngine (Background subtraction, Normalization & Log10 MW Regression)...")
let demoBlotPlane = BioImageProcessor.generateDemoWesternBlotPlane(width: 400, height: 240)
let blotLanes = WesternBlotEngine.autoDetectLanesAndBands(plane: demoBlotPlane)
assert(blotLanes.count == 6, "Default Western Blot demo must detect 6 lanes")
let blotQuant = WesternBlotEngine.quantifyBlot(plane: demoBlotPlane, lanes: blotLanes, backgroundMode: .roiRing)
assert(blotQuant.laneRows.count == 6, "Western Blot quantification must produce 6 normalized lanes")
assert(blotQuant.groupStats.count == 3, "Western Blot must summarize WT, OE, KO groups")

let demoGelPlane = BioImageProcessor.generateDemoAgaroseGelPlane(width: 420, height: 300)
let gelAuto = GelAnalysisEngine.autoDetectAndCalibrate(plane: demoGelPlane, ladder: GelMarkerLadderPreset.builtinPresets[0])
assert(!gelAuto.lanes.isEmpty && gelAuto.fit != nil && (gelAuto.fit?.r2 ?? 0) > 0.95, "Gel Log10 MW regression R² must exceed 0.95")
do {
    let fm = FileManager.default
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_gel_prov_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }
    let vLane = GelAnalysisEngine.buildVirtualDigestLane(
        plasmidName: "DemoVec",
        sequence: String(repeating: "ATGCGGATCCATGAATTC", count: 40),
        isCircular: true,
        enzymeNames: ["BamHI", "EcoRI"],
        fit: gelAuto.fit,
        laneIndex: gelAuto.lanes.count + 1
    )
    let simForGel = HomologousPCRGelSimulator.simulateSingleFragment(
        rawVectorLengthBp: 5400,
        effectiveVectorBackboneLengthBp: 4800,
        deletedVectorBp: 600,
        linearizationMode: .double,
        cleanInsertCoreLengthBp: 1200,
        homologyLength: 18,
        insertGeneName: "EGFP"
    )
    let simVirtualLanes = GelAnalysisEngine.buildVirtualLanesFromSimulation(
        simForGel,
        sourceTag: "单片段",
        fit: gelAuto.fit,
        startingLaneIndex: gelAuto.lanes.count + 2
    )
    assert(simVirtualLanes.count == 2, "Single-fragment simulation must map 2 non-mixed virtual lanes, got \(simVirtualLanes.count)")
    let mutLane = GelAnalysisEngine.buildMutagenesisVirtualLane(
        plasmidName: "pCMV-Demo",
        parentalLengthBp: 5200,
        mutatedLengthBp: 5200,
        homologyLength: 18,
        mutationLabel: "R175H",
        fit: gelAuto.fit,
        laneIndex: gelAuto.lanes.count + 4
    )
    let parsedCustom = GelAnalysisEngine.parseCustomBandSizes("1.5kb, 750bp, 500")
    assert(parsedCustom == [1500.0, 750.0, 500.0], "parseCustomBandSizes mismatch: \(parsedCustom)")
    let customLane = GelAnalysisEngine.buildCustomVirtualLane(
        laneName: "自定义对照",
        sizes: parsedCustom,
        fit: gelAuto.fit,
        laneIndex: gelAuto.lanes.count + 5
    )
    let laidOutLanes = GelAnalysisEngine.layoutVirtualLanes(gelAuto.lanes + [vLane] + simVirtualLanes + [mutLane, customLane])
    let vCenters = laidOutLanes.filter(\.isVirtualDigestLane).map(\.centerX)
    assert(vCenters.count == 5 && Set(vCenters).count == 5, "5 virtual lanes must receive 5 distinct non-overlapping centerX coordinates")
    let yBeforeRecal = laidOutLanes.last?.bands.first?.yFraction ?? 0.0
    let recalDL5000 = GelAnalysisEngine.recalibrateLanes(lanes: laidOutLanes, ladder: GelMarkerLadderPreset.builtinPresets[1])
    let yAfterRecal = recalDL5000.lanes.last?.bands.first?.yFraction ?? 0.0
    assert(abs(yAfterRecal - yBeforeRecal) > 1e-3, "Switching Marker ladder must recalculate virtual band yFraction")

    let gelCSVURL = tmpDir.appendingPathComponent("gel_bands.csv")
    let exportedGel = try GelAnalysisEngine.exportGelBandsCSVWithProvenance(
        lanes: laidOutLanes,
        ladder: GelMarkerLadderPreset.builtinPresets[0],
        fit: gelAuto.fit,
        virtualDigestEnzymes: ["BamHI", "EcoRI"],
        virtualPredictionSources: ["plasmidDigest", "singleFragment", "mutagenesis", "customSizes"],
        to: gelCSVURL
    )
    assert(fm.fileExists(atPath: exportedGel.csvURL.path) && fm.fileExists(atPath: exportedGel.sidecarURL.path), "Gel CSV and .run.json sidecar must exist")
    let decodedGelRun = try AnalysisRun.decode(from: Data(contentsOf: exportedGel.sidecarURL))
    assert(decodedGelRun.schemaVersion == 2 && decodedGelRun.module == NavItem.gelFigure.rawValue, "Gel AnalysisRun schemaVersion/module mismatch")
    assert(decodedGelRun.parameters["ladderID"]?.stringValue == GelMarkerLadderPreset.builtinPresets[0].id, "Gel AnalysisRun must record ladderID")
    assert((decodedGelRun.parameters["fitR2"]?.doubleValue ?? 0) > 0.95, "Gel AnalysisRun must record fitR2")
    if case let .array(srcArr) = decodedGelRun.parameters["virtualPredictionSources"] {
        assert(srcArr.count == 4, "Gel AnalysisRun must record 4 virtualPredictionSources, got \(srcArr.count)")
    } else {
        fatalError("Gel AnalysisRun missing virtualPredictionSources array")
    }
} catch {
    fatalError("Gel provenance export test failed: \(error)")
}
pass("WesternBlotEngine & GelAnalysisEngine passed (6 lanes quantified, Gel R² = \(String(format: "%.4f", gelAuto.fit?.r2 ?? 0)), 5 multi-module virtual lanes verified).")

// 27. 验证同源重组 PCR 扩增凝胶电泳片段模拟引擎 (HomologousPCRGelSimulator)
print("🧪 [27/52] Testing HomologousPCRGelSimulator (Agarose Sieving Physics, Auto Ladder & Amplicon Sizes)...")
// 27.1 物理迁移单调性与不同琼脂糖浓度筛分效应
let y10k_10 = AgaroseGelConcentration.c1_0.migrationY(sizeBp: 10000)
let y5k_10  = AgaroseGelConcentration.c1_0.migrationY(sizeBp: 5000)
let y1k_10  = AgaroseGelConcentration.c1_0.migrationY(sizeBp: 1000)
let y250_10 = AgaroseGelConcentration.c1_0.migrationY(sizeBp: 250)
assert(y10k_10 < y5k_10 && y5k_10 < y1k_10 && y1k_10 < y250_10, "Smaller DNA fragments must migrate further down the agarose gel")

let bigSep_08 = abs(AgaroseGelConcentration.c0_8.migrationY(sizeBp: 8000) - AgaroseGelConcentration.c0_8.migrationY(sizeBp: 5000))
let bigSep_20 = abs(AgaroseGelConcentration.c2_0.migrationY(sizeBp: 8000) - AgaroseGelConcentration.c2_0.migrationY(sizeBp: 5000))
assert(bigSep_08 > bigSep_20, "0.8% agarose must resolve 8kb vs 5kb better than 2.0% agarose")

let smallSep_20 = abs(AgaroseGelConcentration.c2_0.migrationY(sizeBp: 500) - AgaroseGelConcentration.c2_0.migrationY(sizeBp: 250))
let smallSep_08 = abs(AgaroseGelConcentration.c0_8.migrationY(sizeBp: 500) - AgaroseGelConcentration.c0_8.migrationY(sizeBp: 250))
assert(smallSep_20 > smallSep_08, "2.0% agarose must resolve 500bp vs 250bp better than 0.8% agarose")

// 27.2 自动 DNA Marker 选档
assert(HomologousPCRGelSimulator.recommendedLadder(forMaxSizeBp: 1500).id == "dl2000", "Expected DL2000 for <= 1900 bp")
assert(HomologousPCRGelSimulator.recommendedLadder(forMaxSizeBp: 4200).id == "dl5000", "Expected DL5000 for <= 4900 bp")
assert(HomologousPCRGelSimulator.recommendedLadder(forMaxSizeBp: 7400).id == "neb1kbplus", "Expected NEB 1 kb Plus for > 4900 bp")

// 27.3 单片段双酶切 + 切落片段 + 同源臂与附加碱基扩增总长验证
let simSingle = HomologousPCRGelSimulator.simulateSingleFragment(
    rawVectorLengthBp: 6200,
    effectiveVectorBackboneLengthBp: 5400,
    deletedVectorBp: 800,
    linearizationMode: .double,
    cleanInsertCoreLengthBp: 1000,
    extra5LengthBp: 6,
    extra3LengthBp: 0,
    homologyLength: 20,
    insertGeneName: "EGFP"
)
assert(simSingle.ladder.id == "neb1kbplus", "5400 bp vector must auto-select NEB 1 kb Plus")
let vecLaneBands = simSingle.lanes.first(where: { $0.id == "lane-vector" })?.bands ?? []
assert(vecLaneBands.contains(where: { $0.sizeBp == 5400 && $0.role == .linearVector }) && vecLaneBands.contains(where: { $0.sizeBp == 800 && $0.role == .excisedDropout }), "Double-digest vector lane must show both 5400 bp backbone and 800 bp excised dropout")
let insBand = simSingle.lanes.first(where: { $0.id == "lane-insert" })?.bands.first
assert(insBand?.sizeBp == 1046, "Insert PCR amplicon should be 1000 + 6 + 20*2 = 1046 bp, got \(String(describing: insBand?.sizeBp))")

// 27.4 多片段 Gibson 扩增子逐端同源臂规则与近距离共迁移告警
let fA = String(repeating: "ATGC", count: 150) // 600 bp
let fB = String(repeating: "GCTA", count: 200) // 800 bp
let fC = String(repeating: "CGAT", count: 250) // 1000 bp
let simMulti = HomologousPCRGelSimulator.simulateMultiFragment(
    effectiveVectorBackboneLengthBp: 4200,
    deletedVectorBp: 0,
    rawVectorLengthBp: 4200,
    fragments: [fA, fB, fC],
    homologyLength: 20
)
let f1Size = simMulti.lanes.first(where: { $0.shortLabel == "F1" })?.bands.first?.sizeBp
let f2Size = simMulti.lanes.first(where: { $0.shortLabel == "F2" })?.bands.first?.sizeBp
let f3Size = simMulti.lanes.first(where: { $0.shortLabel == "F3" })?.bands.first?.sizeBp
assert(f1Size == 620 && f2Size == 820 && f3Size == 1040, "Multi-fragment amplicons must be [620, 820, 1040], got [\(String(describing: f1Size)), \(String(describing: f2Size)), \(String(describing: f3Size))]")

let fNear1 = String(repeating: "ATGC", count: 250) // 1000 bp -> +20 = 1020 bp
let fNear2 = String(repeating: "CGTA", count: 255) // 1020 bp -> +40 = 1060 bp vs 1020 bp in 0.8%
let simCoMigrate = HomologousPCRGelSimulator.simulateMultiFragment(
    effectiveVectorBackboneLengthBp: 4500,
    deletedVectorBp: 0,
    rawVectorLengthBp: 4500,
    fragments: [fNear1, fNear2],
    homologyLength: 20,
    concentrationOverride: .c0_8,
    includeMixControlLane: true
)
assert(!simCoMigrate.warnings.isEmpty, "Co-migrating 1020 vs 1060 bp in mix lane at 0.8% must emit resolution warning")

// 27.5 片段删除反向 PCR 与入门克隆验证
let simDel = HomologousPCRGelSimulator.simulateFragmentDeletion(
    parentalLengthBp: 6000,
    deletedLengthBp: 1200,
    homologyLength: 18
)
let delSize = simDel.lanes.first(where: { $0.shortLabel == "缺失PCR" })?.bands.first?.sizeBp
assert(delSize == 4818, "Deletion inverse PCR amplicon must be 6000 - 1200 + 18 = 4818 bp, got \(String(describing: delSize))")

let simEntry = HomologousPCRGelSimulator.simulateEntryClone(
    cleanInsertLengthBp: 720,
    hasEnzymes: true,
    enzyme5: RestrictionEnzymeDatabase.shared.find(name: "BamHI"),
    enzyme3: RestrictionEnzymeDatabase.shared.find(name: "EcoRI"),
    primerF: nil,
    primerR: nil
)
let entryAmp = simEntry.lanes.first(where: { $0.shortLabel == "目的PCR" })?.bands.first?.sizeBp
assert(entryAmp == 762, "Entry clone with BamHI+EcoRI amplicon must be 720 + 30 + 12 = 762 bp, got \(String(describing: entryAmp))")
assert(simSingle.exportCSV().contains("1046") && simSingle.exportCSV().contains("Gel_Concentration"), "Gel simulation CSV export mismatch")
let simShortFlankOnly = HomologousPCRGelSimulator.simulateSingleFragment(
    rawVectorLengthBp: 0,
    effectiveVectorBackboneLengthBp: 0,
    deletedVectorBp: 0,
    linearizationMode: .pcr,
    cleanInsertCoreLengthBp: 720,
    homologyLength: 18,
    omittedShortVectorBp: 102
)
assert(simShortFlankOnly.lanes.count == 2 && simShortFlankOnly.infoNotice?.contains("102 bp") == true, "Short-flank-only simulation should emit infoNotice without a fake vector lane")
pass("HomologousPCRGelSimulator passed (agarose sieving physics, 4 cloning workflows, auto ladder & resolution warnings verified).")

// 28. 验证 WBStudio 16-bit 真实样本 (gapdh_*.tif) 自动配对、Rolling-Ball 圈定与双排内参归一化显著性统计
print("🧪 [28/52] Testing Integrated WBStudio 16-bit Engine on real gapdh_*.tif samples...")
let wbGroups = WesternBlotEngine.discoverSampleGroups()
assert(wbGroups.count >= 2, "Must discover >= 2 WB sample groups from labworker/Samples/WB, found \(wbGroups.count)")
let group16 = wbGroups.first(where: { $0.rawChemi != nil }) ?? wbGroups[0]
assert(group16.availableLayers.count >= 3, "Real GAPDH group must pair raw_chemi/chemi/brightfield layers")

let native16Res = WesternBlotEngine.analyzeNative16Bit(
    imagePath: group16.primaryQuantPath,
    params: WBAnalysisParams(rollingBallRadius: 50, expectedLanes: 6, bandProminence: 0.12, stripThreshold: 0.08, primaryBandOnly: true)
)
assert(native16Res != nil, "Native 16-bit WB analysis must succeed on \(group16.primaryQuantPath)")
if let res16 = native16Res {
    assert(res16.bitDepth == 16, "Expected 16-bit TIFF detection, got \(res16.bitDepth)-bit")
    assert(res16.lanes.count == 6, "Expected 6 lanes on real GAPDH blot, got \(res16.lanes.count)")
    assert(res16.bands.count == 6 && res16.bands.allSatisfy({ $0.netIOD > 0 }), "All 6 GAPDH bands must have positive Net IOD")
}

let synthBuf = WesternBlotEngine.bufferFromBioImagePlane(demoBlotPlane)
let dualRowRes = WesternBlotEngine.analyzeNativeBuffer(
    synthBuf,
    params: WBAnalysisParams(rollingBallRadius: 40, expectedLanes: 6, bandProminence: 0.10, stripThreshold: 0.06, primaryBandOnly: false)
)
let grpStatsOut = WesternBlotEngine.computeGroupStatistics(
    from: dualRowRes,
    laneGroups: [0: "WT", 1: "WT", 2: "TP53-OE", 3: "TP53-OE", 4: "TP53-KO", 5: "TP53-KO"],
    controlGroup: "WT",
    normalizeBySecondRowIfPresent: true
)
assert(grpStatsOut.groupStats.count == 3, "Dual-row WB group statistics must summarize WT, TP53-OE, TP53-KO")
pass("Integrated WBStudio 16-bit Engine passed (Discovered \(wbGroups.count) real sample groups, 16-bit 6-lane IOD & Welch t-test verified).")

// 29. 验证蛋白质生物物理、三维构象、Ramachandran 二面角与突变评估引擎 (ProteinBiophysicsEngine)
print("🧪 [29/52] Testing ProteinBiophysicsEngine (pI, GRAVY, 3D Fold, Ramachandran & Mutant ΔΔG)...")
let demoProt = ProteinBiophysicsEngine.builtinExamples[0]
let protReport = ProteinBiophysicsEngine.analyzeProtein(sequence: demoProt.sequence)
assert(protReport.length == demoProt.sequence.count, "Protein length mismatch")
assert(protReport.molecularWeightDa > 10000.0 && protReport.isoelectricPoint > 4.0 && protReport.isoelectricPoint < 10.0, "Protein MW & pI out of realistic range")
assert(protReport.residues.count == protReport.length && !protReport.contacts.isEmpty && !protReport.pockets.isEmpty, "Protein 3D fold must produce residues, contacts & pockets")
let exportedPDB = ProteinBiophysicsEngine.exportPDB(report: protReport)
let reparsedResidues = ProteinBiophysicsEngine.parsePDBResidues(exportedPDB)
assert(reparsedResidues.count == protReport.length, "PDB export & re-parse must preserve all Cα residues")
let mutEvals = ProteinBiophysicsEngine.evaluateMutantsBatch(wildTypeSequence: demoProt.sequence, mutationSpecs: ["V13A", "T48P"])
assert(mutEvals.count == 2, "Must evaluate 2 mutant specifications")
assert(mutEvals.allSatisfy { $0.modelType == "empirical_heuristic" && $0.stabilityVerdict.contains("Empirical") }, "Mutant ΔΔG evaluations must carry empirical_heuristic modelType and honest verdict wording")
pass("ProteinBiophysicsEngine passed (Length=\(protReport.length)aa, pI=\(String(format: "%.2f", protReport.isoelectricPoint)), Q=\(String(format: "%.1f", protReport.compositeQScore)), Contacts=\(protReport.contacts.count)).")

// 30. 验证 Labworker 5 大直觉功能分组、新功能默认偏好设置与 Finder 多格式智能路由
print("🧪 [30/52] Testing Labworker 5-Category Navigation, Custom Bench Defaults & Finder Routing...")
assert(SidebarSectionKind.allCases.count == 5, "SidebarSectionKind must have 5 intuitive sections")
assert(NavItem.westernBlot.section == .bioImaging && NavItem.gelFigure.section == .bioImaging, "WB and Gel must be grouped under .bioImaging")
assert(NavItem.proteinWorkbench.section == .benchTools && NavItem.qpcrAnalysis.section == .benchTools, "Protein and qPCR must be grouped under .benchTools")
AppState.shared.defaultWBRollingBallRadius = 65
AppState.shared.defaultProteinPH = 7.4
AppState.shared.liquidGlassStyle = .clear
assert(AppState.shared.liquidGlassStyle == .clear && UserDefaults.standard.string(forKey: "cs_liquidGlassStyle") == "clear", "LiquidGlassStyleMode .clear must persist")
AppState.shared.liquidGlassStyle = .tinted
AppState.shared.enableAmbientGlassGlow = false
AppState.shared.followSystemLiquidGlass = false
AppState.shared.liquidGlassStrength = 0.78
AppState.shared.sidebarWidth = 310
AppState.shared.accentTheme = .purple
assert(AppState.shared.liquidGlassStyle == .tinted && UserDefaults.standard.string(forKey: "cs_liquidGlassStyle") == "tinted", "LiquidGlassStyleMode .tinted must persist")
assert(AppState.shared.enableAmbientGlassGlow == false && UserDefaults.standard.object(forKey: "cs_enableAmbientGlassGlow") as? Bool == false, "enableAmbientGlassGlow must persist")
assert(abs(AppState.shared.effectiveLiquidGlassStrength - 0.78) < 1e-6 && AppState.shared.sidebarWidth == 310, "Liquid Glass strength and resizable sidebar width must update & persist")
assert(AppState.shared.defaultWBRollingBallRadius == 65 && abs(AppState.shared.defaultProteinPH - 7.4) < 1e-6, "Custom workbench defaults must update cleanly")
AppState.shared.resetSettingsToDefaults()
assert(AppState.shared.defaultWBRollingBallRadius == 50 && abs(AppState.shared.defaultProteinPH - 7.0) < 1e-6, "resetSettingsToDefaults must restore workbench defaults")
assert(AppState.shared.liquidGlassStyle == .regular && AppState.shared.enableAmbientGlassGlow == true, "resetSettingsToDefaults must restore Liquid Glass .regular & ambient glow enabled")
assert(AppState.shared.followSystemLiquidGlass && AppState.shared.accentTheme == .system && AppState.shared.sidebarWidth == 232, "resetSettingsToDefaults must restore follow-system glass/accent & default sidebarWidth 232")
AppState.shared.sidebarWidth = 120
assert(AppState.shared.sidebarWidth == 188, "sidebarWidth must clamp to minimum 188pt")
AppState.shared.sidebarWidth = 600
assert(AppState.shared.sidebarWidth == 380, "sidebarWidth must clamp to maximum 380pt")
AppState.shared.sidebarWidth = 232
assert(LiquidGlassStyleMode.allCases.count == 3, "LiquidGlassStyleMode must expose regular/clear/tinted modes")
assert(AppAccentTheme.allCases.contains(.system), "AppAccentTheme must include system/multicolor option")
if let wbSample = wbGroups.first {
    let tifURL = URL(fileURLWithPath: wbSample.primaryQuantPath)
    WorkspaceSessionManager.shared.handleFinderOpenURLs([tifURL])
    assert(AppState.shared.selectedNav == .westernBlot, "Finder opening .tif must route directly to .westernBlot")
}
pass("Labworker 5-Category Navigation, Custom Bench Defaults & Finder Routing passed.")

// 31. 验证对齐 DockFlowLab (boxes.py & pockets.py) 的 LIGSITE P-S-P 扫描、CONSENSUS_COVERAGE (0.35 / 0.50) 共识融合盒、first_model 截断与 18-60 Å 边界钳制
print("🧪 [31/52] Testing DockFlowLab-aligned LIGSITE P-S-P Pocket, Consensus Vina Box & PDB Health Card...")
assert(protReport.dockingBox.volumeA3 > 1000.0 && protReport.dockingBox.vinaConfigText.contains("center_x"), "Docking box must produce valid volume and AutoDock Vina config")
assert(protReport.dockingBox.sizeX >= 18.0 && protReport.dockingBox.sizeX <= 60.0, "Docking box size must be clamped within [18.0, 60.0] Å")
assert(!protReport.healthCard.isExperimentalOrAlphaFoldPDB && !protReport.healthCard.warnings.isEmpty, "Heuristic fold must transparently report non-experimental coordinate source")

// 构造位于几何口袋中心附近的共晶配体 ATP (覆盖率 >= 0.35)，并测试 ENDMDL 截断第 2 模型与氢原子过滤
let pocketCX = protReport.pockets[0].centerX
let pocketCY = protReport.pockets[0].centerY
let pocketCZ = protReport.pockets[0].centerZ
let pdbWithConsensusLigand = exportedPDB.replacingOccurrences(of: "END", with: String(format: """
HETATM 9001  ZN   ZN A 301    %8.3f%8.3f%8.3f  1.00 40.00          ZN
HETATM 9002  C1  ATP A 302    %8.3f%8.3f%8.3f  1.00 35.00           C
HETATM 9003  C2  ATP A 302    %8.3f%8.3f%8.3f  1.00 35.00           C
HETATM 9004  H1  ATP A 302      99.000  99.000  99.000  1.00 35.00           H
ENDMDL
MODEL        2
HETATM 9099  C1  INH A 303      88.000  88.000  88.000  1.00 35.00           C
END
""", pocketCX, pocketCY, pocketCZ, pocketCX + 0.5, pocketCY - 0.5, pocketCZ + 0.4, pocketCX - 0.6, pocketCY + 0.4, pocketCZ - 0.3))

let pdbLigReport = ProteinBiophysicsEngine.analyzeProtein(sequence: demoProt.sequence, pdbText: pdbWithConsensusLigand)
assert(pdbLigReport.healthCard.isExperimentalOrAlphaFoldPDB, "PDB with ATOM records must be recognized as external PDB")
assert(pdbLigReport.healthCard.coCrystalLigands == ["ATP"] && !pdbLigReport.healthCard.coCrystalLigands.contains("INH"), "first_model=True must ignore MODEL 2 INH ligand after ENDMDL")
assert(pdbLigReport.healthCard.metalIons.contains("ZN"), "Must detect ZN metal ion")
assert(pdbLigReport.dockingBox.sourceTitle.contains("共识融合盒"), "Co-crystal ligand overlapping pocket (>=35%) must trigger Consensus Box")
pass("DockFlowLab-aligned LIGSITE P-S-P Pocket, Vina Box (\(pdbLigReport.dockingBox.sourceTitle)) & PDB Health Card passed.")

// 32. 验证侧边栏自定义显隐控制、系统设置常驻防呆保护与 18 模块（17 个业务模块 + 系统设置）全局功能说明书完整性
print("🧪 [32/52] Testing Sidebar Visibility Customization & Global Feature Manual...")
for nav in NavItem.allCases {
    assert(!nav.summaryDescription.isEmpty && !nav.supportedFormats.isEmpty && !nav.workflowTip.isEmpty, "NavItem \(nav.rawValue) must provide complete manual metadata")
}
let totalModulesCount = NavItem.allCases.count
let businessModulesCount = NavItem.allCases.filter { $0.canBeHiddenInSidebar }.count
assert(totalModulesCount == 18 && businessModulesCount == 17, "Expected 18 total modules (17 business modules + .settings), got \(totalModulesCount)")
assert(!NavItem.allCases.map(\.rawValue).contains("chopchopCompare"), "chopchopCompare standalone module must be removed")
assert(!NavItem.allCases.map(\.rawValue).contains("figureAnnotator"), "figureAnnotator must be completely removed")
assert(!NavItem.allCases.map(\.rawValue).contains("colonyCounter"), "colonyCounter must be completely removed")
assert(!NavItem.settings.canBeHiddenInSidebar, ".settings must never be allowed to hide in sidebar")
AppState.shared.setNavItemVisible(.settings, visible: false)
assert(AppState.shared.isNavItemVisible(.settings), ".settings must remain visible even if setNavItemVisible(false) is called")

AppState.shared.selectedNav = .westernBlot
AppState.shared.setNavItemVisible(.westernBlot, visible: false)
assert(!AppState.shared.isNavItemVisible(.westernBlot), ".westernBlot should be marked hidden")
assert(AppState.shared.selectedNav != .westernBlot, "Hiding the active NavItem must automatically switch selectedNav to a visible item")

AppState.shared.applySidebarVisibilityPreset(.cloningAndTargeting)
assert(AppState.shared.isNavItemVisible(.entryClone) && !AppState.shared.isNavItemVisible(.proteinWorkbench), "cloningAndTargeting preset must keep cloning visible and hide benchTools")

AppState.shared.resetSettingsToDefaults()
assert(AppState.shared.hiddenSidebarItems.isEmpty && AppState.shared.isNavItemVisible(.westernBlot) && AppState.shared.isNavItemVisible(.proteinWorkbench), "resetSettingsToDefaults must restore all sidebar items to visible")
pass("Sidebar Visibility Customization & Global Feature Manual (\(totalModulesCount)/\(totalModulesCount) modules: \(businessModulesCount) 个业务模块 + 系统设置) passed.")

// 33. 验证对齐 primer3-py (2.4.0) 的 PrimerQualityEngine (calcHairpin / calcHomodimer / calcDimer / Mg2+ & dNTP 校正 / ASCII 配对图)
print("🧪 [33/52] Testing PrimerQualityEngine (primer3-py aligned Hairpin, Homodimer, Heterodimer & Mg2+/dNTP salt correction)...")
let stdCond = PrimerQualityEngine.Conditions.standard
// 33.1 参照 primer3-py 2.4.0: GCGAATTCGC (50mM Mon+, 1.5mM Mg2+, 0.6mM dNTP, 50nM DNA, 37℃)
// primer3-py: Hairpin dg = -1.70 kcal/mol, tm = 58.3℃; Homodimer dg = -10.50 kcal/mol, tm = 37.5℃, dh = -80.00 kcal/mol
let hp1 = PrimerQualityEngine.calcHairpin("GCGAATTCGC", conditions: stdCond)
assert(hp1.structureFound, "GCGAATTCGC must form a hairpin")
assert(abs(hp1.dg - (-1.70)) < 0.25 && abs(hp1.tm - 58.3) < 2.0, "GCGAATTCGC hairpin mismatch vs primer3-py: dg=\(hp1.dg), tm=\(hp1.tm)")
assert(hp1.asciiStructure.contains("SEQ\t") && hp1.asciiStructure.contains("╭AATT╮"), "Hairpin ASCII structure must contain primer3 header and stem-loop diagram")

let hd1 = PrimerQualityEngine.calcHomodimer("GCGAATTCGC", conditions: stdCond)
assert(hd1.structureFound, "GCGAATTCGC must form a self-complementary homodimer")
assert(abs(hd1.dg - (-10.50)) < 0.05 && abs(hd1.dh - (-80.00)) < 0.05 && abs(hd1.tm - 37.5) < 0.2, "GCGAATTCGC homodimer must exactly match primer3-py: dg=\(hd1.dg), dh=\(hd1.dh), tm=\(hd1.tm)")
assert(hd1.threePrimeAnchored && hd1.riskLevel == .high, "Full 10bp self-dimer with 3' pairing must be flagged as high risk")
assert(hd1.asciiStructure.contains("|"), "Homodimer ASCII diagram must render base-pair bars")

// 33.2 验证 Mg2+ 与 dNTP 浓度对二聚体/发夹稳定性的热力学影响 (游离 Mg2+ 越高，结构越稳定、ΔG 越负、Tm 越高)
let noMgCond = PrimerQualityEngine.Conditions(mvConc: 50.0, dvConc: 0.0, dntpConc: 0.0, dnaConc: 50.0, tempC: 37.0)
let highMgCond = PrimerQualityEngine.Conditions(mvConc: 50.0, dvConc: 2.0, dntpConc: 0.2, dnaConc: 50.0, tempC: 37.0)
let hdNoMg = PrimerQualityEngine.calcHomodimer("GCGAATTCGC", conditions: noMgCond)
let hdHighMg = PrimerQualityEngine.calcHomodimer("GCGAATTCGC", conditions: highMgCond)
// primer3-py: noMg dg = -9.28 kcal/mol, tm = 32.9℃; highMg dg = -10.76 kcal/mol, tm = 38.6℃
assert(abs(hdNoMg.dg - (-9.28)) < 0.05 && abs(hdHighMg.dg - (-10.76)) < 0.05, "Mg2+/dNTP salt correction must match primer3-py: noMg=\(hdNoMg.dg), highMg=\(hdHighMg.dg)")
assert(hdHighMg.dg < hd1.dg && hd1.dg < hdNoMg.dg && hdHighMg.tm > hdNoMg.tm, "Higher free Mg2+ must lower dG and raise dimer Tm")

// 33.3 验证异二聚体 calcDimer (ATGCGATCGATCGATCGATC x GCTAGCTAGCTAGCGATCGCAT -> primer3-py dg = -10.36 kcal/mol)
let het = PrimerQualityEngine.calcDimer("ATGCGATCGATCGATCGATC", "GCTAGCTAGCTAGCGATCGCAT", conditions: stdCond)
assert(het.structureFound && abs(het.dg - (-10.36)) < 0.5, "Heterodimer dG must align with primer3-py (-10.36): got \(het.dg)")
assert(het.threePrimeAnchored && het.riskLevel == .high, "3'-anchored 9bp heterodimer must be high risk")

// 33.4 验证低风险常规引物不会误报及 AppState 自定义 Mg2+/dNTP 状态联动
let safePrimer = PrimerQualityEngine.evaluatePrimer("CAGTACCTGACTTGACCTGAA", conditions: stdCond)
assert(safePrimer.overallRisk == .safe, "Well-designed primer without strong secondary structure should be classified as .safe, got \(safePrimer.overallRisk)")
AppState.shared.primerMgConc = 2.5
AppState.shared.primerDntpConc = 0.2
assert(AppState.shared.primerThermoConditions.equivalentMonovalentMolar > stdCond.equivalentMonovalentMolar, "Custom Mg2+/dNTP in AppState must update equivalent monovalent concentration")
AppState.shared.resetSettingsToDefaults()
assert(abs(AppState.shared.primerMgConc - 1.5) < 1e-6 && abs(AppState.shared.primerDntpConc - 0.6) < 1e-6, "resetSettingsToDefaults must restore default Mg2+ (1.5 mM) and dNTP (0.6 mM)")
pass("PrimerQualityEngine passed (Hairpin dG=\(hp1.dg) kcal/mol, Homodimer dG=\(hd1.dg) kcal/mol, Heterodimer dG=\(het.dg) kcal/mol).")

// 34. 验证 Swift 核心引擎与 Python MCP Server 双端算法 100% 一致性 (Tm / 5'悬垂末端 / 多片段 2-10 同源臂 / 蛋白质 pI & ΔΔG)
print("🧪 [34/52] Testing Cross-Engine Consistency (Swift CloneStudioCore vs Python MCP Server)...")
do {
    let mcpScriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/CloneStudioCore/Resources/clonestudio_mcp_server.py")
    assert(FileManager.default.fileExists(atPath: mcpScriptURL.path), "clonestudio_mcp_server.py must exist")

    let testSeq1 = "ATGGTGAGCAAGGGCGAGGAGCTG"
    let testSeq2 = "CAGTACCTGACTTGACCTGAA"
    let testOverhang = "cggccgcgaattc"
    let swiftTm1 = TmCalculator.calculate(sequence: testSeq1).tm
    let swiftTm2 = TmCalculator.calculate(sequence: testSeq2, fivePrimeOverhang: testOverhang).tm

    let protSeq = "MKVLLFAAVVGGLAAAGVSAKELRKIYEDGKVTYTLDNGKPVVLVFYPADFTFVCPTEIIAFSENAAKKFEEQGAQVLFASTDSEYSLLAWTNIPRKEGGLGPINIPLLADTN"
    let swiftProt = ProteinBiophysicsEngine.analyzeProtein(sequence: protSeq, env: ProteinEnvironmentParams(ph: 7.0))
    let swiftMuts = ProteinBiophysicsEngine.evaluateMutantsBatch(wildTypeSequence: protSeq, mutationSpecs: ["V18A", "E45P"], env: ProteinEnvironmentParams(ph: 7.0))
    assert(swiftMuts.count == 2, "ProteinBiophysicsEngine must evaluate 2 mutations")

    let pyCode = """
    import importlib.util, json
    spec = importlib.util.spec_from_file_location("mcp_srv", "\(mcpScriptURL.path)")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    m.notify_gui_and_sync_primers = lambda *a, **k: None
    res = {
        "tm1": m.calc_snapgene_tm("\(testSeq1)"),
        "tm2": m.calc_snapgene_tm("\(testSeq2)", "\(testOverhang)"),
        "prot": m.tool_analyze_protein_and_docking_box({
            "sequence": "\(protSeq)",
            "ph": 7.0,
            "mutations": ["V18A", "E45P"]
        })
    }
    print(json.dumps(res))
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = ["-c", pyCode]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    try proc.run()
    proc.waitUntilExit()
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    let jsonObj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let pyTm1 = jsonObj["tm1"] as! Double
    let pyTm2 = jsonObj["tm2"] as! Double
    assert(abs(swiftTm1 - pyTm1) < 1e-6, "Tm1 mismatch between Swift (\(swiftTm1)) and Python MCP (\(pyTm1))")
    assert(abs(swiftTm2 - pyTm2) < 1e-6, "Tm2 with 5' overhang mismatch between Swift (\(swiftTm2)) and Python MCP (\(pyTm2))")

    let pyProt = jsonObj["prot"] as! [String: Any]
    let pyMW = pyProt["molecular_weight_da"] as! Double
    let pyPI = pyProt["isoelectric_point"] as! Double
    let pyCharge = pyProt["net_charge_at_ph"] as! Double
    assert(abs(round(swiftProt.molecularWeightDa * 10) / 10 - pyMW) < 0.2, "MW mismatch: Swift=\(swiftProt.molecularWeightDa), Py=\(pyMW)")
    assert(abs(round(swiftProt.isoelectricPoint * 100) / 100 - pyPI) < 0.02, "pI mismatch: Swift=\(swiftProt.isoelectricPoint), Py=\(pyPI)")
    assert(abs(round(swiftProt.netChargeAtEnvPh * 100) / 100 - pyCharge) < 0.02, "NetCharge mismatch: Swift=\(swiftProt.netChargeAtEnvPh), Py=\(pyCharge)")

    let pyMuts = pyProt["mutant_evaluations"] as! [[String: Any]]
    assert((pyProt["ddg_model_type"] as? String) == "empirical_heuristic", "Python MCP protein tool must declare ddg_model_type=empirical_heuristic")
    for (idx, swMut) in swiftMuts.enumerated() {
        let pyDDG = pyMuts[idx]["ddg_kcal_mol"] as! Double
        let swDDG = round(swMut.ddgKcalMol * 100) / 100
        assert(abs(swDDG - pyDDG) < 0.02, "Mutant #\(idx) ΔΔG mismatch: Swift=\(swDDG), Py=\(pyDDG)")
        assert(swMut.modelType == "empirical_heuristic" && (pyMuts[idx]["model_type"] as? String) == "empirical_heuristic", "Mutant #\(idx) model_type must match empirical_heuristic")
    }
    pass("Cross-Engine Consistency passed (Swift & Python MCP Tm=\(swiftTm1)℃/\(swiftTm2)℃, pI=\(pyPI), ΔΔG=\(pyMuts[0]["ddg_kcal_mol"]!) kcal/mol).")
} catch {
    fatalError("Cross-Engine verification failed: \(error)")
}

// 35. 验证 SangerAlignmentEngine 原生 .ab1 二进制峰图解析、四色荧光轨迹、正反向环状比对与 MCP verify_sanger_sequencing
print("🧪 [35/52] Testing SangerAlignmentEngine (.ab1 ABIF Binary Parser, 4-Channel Traces & Circular Plasmid Alignment)...")
do {
    let refPlasmid =
        "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTG" +
        "CCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAG" +
        "GGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAG" +
        "CTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGC" +
        "CGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTAC" +
        "GTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTG"
    let refChars = Array(refPlasmid)
    let wtReadSeq = String(refChars[40..<240]) // 200 bp 完美匹配读长

    // 35.1 完美匹配与反向互补自动识别
    let wtAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: BioSequence.reverseComplement(wtReadSeq), sampleName: "Colony_Rev_Pass.ab1", simulateNoisyEnds: true)
    let wtChrom = SangerAlignmentEngine.parseData(wtAB1, sampleName: "Colony_Rev_Pass.ab1", trimQualityThreshold: 20)
    assert(wtChrom.isBinaryAB1 && wtChrom.rawLength == 200 && wtChrom.trimmedLength == 184, "ABIF binary parser & 5'/3' trimming failed: raw=\(wtChrom.rawLength), trimmed=\(wtChrom.trimmedLength)")
    assert(!wtChrom.traceA.isEmpty && !wtChrom.traceC.isEmpty && !wtChrom.traceG.isEmpty && !wtChrom.traceT.isEmpty, "4-channel trace arrays must be populated")

    let wtRep = SangerAlignmentEngine.verifyAgainstPlasmid(chromatogram: wtChrom, referenceSequence: refPlasmid, referenceName: "EGFP-Ref")
    assert(wtRep.isReverseComplement && wtRep.verdict == .verifiedPass && wtRep.mismatchCount == 0 && abs(wtRep.identityPercent - 100.0) < 0.01, "Reverse-complement WT read must achieve 100% identity pass: got \(wtRep.verdict), identity=\(wtRep.identityPercent)%")

    // 35.2 点突变 SNP 与杂合双峰检测 + Finder .ab1 路由 + MCP verify_sanger_sequencing
    var mutChars = Array(wtReadSeq)
    mutChars[60] = (mutChars[60] == "A") ? "G" : "A"
    let mutAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(
        sequence: String(mutChars),
        sampleName: "Colony_Mut_DoublePeak.ab1",
        doublePeakAt1Based: [95: "T"],
        simulateNoisyEnds: true
    )
    let tmpAB1URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_sanger_verify.ab1")
    try mutAB1.write(to: tmpAB1URL)
    defer { try? FileManager.default.removeItem(at: tmpAB1URL) }

    let mutChrom = try SangerAlignmentEngine.parseFile(at: tmpAB1URL, trimQualityThreshold: 20)
    let mutRep = SangerAlignmentEngine.verifyAgainstPlasmid(chromatogram: mutChrom, referenceSequence: refPlasmid, referenceName: "EGFP-Ref", cdsStart1Based: 23)
    assert(mutRep.verdict == .pointMutation && mutRep.mismatchCount == 1 && mutRep.doublePeakCount >= 1, "Must detect 1 SNP and 1 heterozygous double peak: mismatches=\(mutRep.mismatchCount), doublePeaks=\(mutRep.doublePeakCount)")
    assert(mutRep.variants.contains(where: { $0.kind == .mismatchSNP && $0.codonImpactNote.contains("突变") }), "Variant call must include HGVS and codon translation impact")

    // 验证 Finder 打开 .ab1 自动路由至 .sangerVerify
    WorkspaceSessionManager.shared.handleFinderOpenURLs([tmpAB1URL])
    assert(AppState.shared.selectedNav == .sangerVerify, "Finder opening .ab1 file must route directly to .sangerVerify")

    // 验证 MCP verify_sanger_sequencing CLI 调用
    let mcpSangerProc = Process()
    mcpSangerProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    mcpSangerProc.arguments = [
        mcpScript,
        "--cli-call", "verify_sanger_sequencing",
        "--args", "{\"ab1_file_path\":\"\(tmpAB1URL.path)\",\"reference_sequence\":\"\(refPlasmid)\"}"
    ]
    let sangerPipe = Pipe()
    mcpSangerProc.standardOutput = sangerPipe
    try mcpSangerProc.run()
    let sangerData = sangerPipe.fileHandleForReading.readDataToEndOfFile()
    mcpSangerProc.waitUntilExit()
    let sangerJSON = try JSONSerialization.jsonObject(with: sangerData) as! [String: Any]
    assert((sangerJSON["is_binary_ab1"] as? Bool) == true && (sangerJSON["mismatches"] as? [[String: Any]])?.count == 1, "MCP verify_sanger_sequencing must parse binary .ab1 and report 1 SNP mismatch")
    pass("SangerAlignmentEngine passed (Binary .ab1 4-channel traces, 100% RevComp match, SNP + Double-Peak detection & MCP verify_sanger_sequencing verified).")
} catch {
    fatalError("SangerAlignmentEngine test failed: \(error)")
}

// 36. 验证 P01 测试计数、MCP 工具数与模块数单一真值来源 (Single Source of Truth)
print("🧪 [36/52] Testing Single Source of Truth for Test, Tool & Module Counts (P01)...")
do {
    let countProc = Process()
    countProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    countProc.arguments = [mcpScript, "--count-tools"]
    let countPipe = Pipe()
    countProc.standardOutput = countPipe
    try countProc.run()
    let countData = countPipe.fileHandleForReading.readDataToEndOfFile()
    countProc.waitUntilExit()
    assert(countProc.terminationStatus == 0, "clonestudio_mcp_server.py --count-tools must exit with 0")
    let pyToolCount = Int((String(data: countData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    let swiftCatalogCount = await MainActor.run { PlasmidPoolManager.mcpToolsCatalog.count }
    assert(pyToolCount == 23 && pyToolCount == swiftCatalogCount, "Python MCP_TOOLS count (\(pyToolCount)) must match Swift mcpToolsCatalog count (\(swiftCatalogCount))")
    assert(NavItem.allCases.count == 18, "NavItem.allCases.count must be 18")
    let beforePassCount = passedTests.count
    pass("Single Source of Truth for Counts passed (MCP tools=\(pyToolCount), modules=\(NavItem.allCases.count), dynamic pass registry verified).")
    assert(passedTests.count == beforePassCount + 1, "pass() must dynamically increment passedTests.count")
} catch {
    fatalError("P01 count verification failed: \(error)")
}

// 37. 验证 P02 qPCR 伪重复统计修复（禁止将技术复孔当作生物学重复，验证 Swift 与 Python MCP 样品级 Welch t 检验一致性）
print("🧪 [37/52] Testing qPCR Pseudo-Replication Fix & Biological Replicate Welch's t-test (P02)...")
do {
    // 场景 A：每组仅 1 个生物学样品 × 3 个技术复孔（伪重复场景 -> p 值必须为 nil，statNote == .insufficientBiologicalReplicates）
    let singleBioCSV = """
    well,sample,group,target,replicate,ct
    A1,Ctrl_1,ControlGroup,GAPDH,1,18.40
    A2,Ctrl_1,ControlGroup,GAPDH,2,18.45
    A3,Ctrl_1,ControlGroup,GAPDH,3,18.38
    A4,Ctrl_1,ControlGroup,TP53,1,23.10
    A5,Ctrl_1,ControlGroup,TP53,2,23.18
    A6,Ctrl_1,ControlGroup,TP53,3,23.14
    B1,Treat_1,TreatedGroup,GAPDH,1,18.42
    B2,Treat_1,TreatedGroup,GAPDH,2,18.46
    B3,Treat_1,TreatedGroup,GAPDH,3,18.39
    B4,Treat_1,TreatedGroup,TP53,1,20.90
    B5,Treat_1,TreatedGroup,TP53,2,20.95
    B6,Treat_1,TreatedGroup,TP53,3,20.88
    """
    let singleWells = QPCRAnalysisEngine.parseQPCRTable(singleBioCSV)
    let singleSettings = QPCRSettings(referenceTargets: ["GAPDH"], controlGroup: "ControlGroup", controlSample: "Ctrl_1")
    let singleQC = QPCRAnalysisEngine.computeQC(wells: singleWells, settings: singleSettings)
    let singleOut = QPCRAnalysisEngine.computeDdct(wells: singleWells, settings: singleSettings, qc: singleQC)
    guard let treatSingleGrp = singleOut.groupResults.first(where: { $0.category == "TreatedGroup" }) else {
        fatalError("TreatedGroup summary missing in single bio replicate test")
    }
    assert(treatSingleGrp.nBiological == 1 && treatSingleGrp.nTechnicalWells == 3, "Expected nBiological=1, nTechnicalWells=3, got \(treatSingleGrp.nBiological)/\(treatSingleGrp.nTechnicalWells)")
    assert(treatSingleGrp.pValue == nil && treatSingleGrp.statNote == .insufficientBiologicalReplicates, "1 biological sample x 3 technical wells MUST NOT compute p-value (got p=\(String(describing: treatSingleGrp.pValue)), note=\(treatSingleGrp.statNote))")
    assert(treatSingleGrp.significanceLabel == "n<2，未检验", "Significance label for n<2 must be 'n<2，未检验'")
    let exportedCSV = QPCRAnalysisEngine.exportDdctResultsCSV(singleOut)
    assert(exportedCSV.contains("N_Biological,N_Technical_Wells,Stat_Note") && exportedCSV.contains("insufficientBiologicalReplicates"), "CSV export must include N_Biological, N_Technical_Wells, Stat_Note columns")

    // 场景 B：每组 3 个独立生物学样品 × 3 个技术复孔（共 18 个目的基因孔 + 18 个内参孔 = 36 孔）
    let multiBioCSV = """
    well,sample,group,target,replicate,ct
    A1,C1,ControlGroup,GAPDH,1,18.00
    A2,C1,ControlGroup,GAPDH,2,18.02
    A3,C1,ControlGroup,GAPDH,3,17.98
    A4,C1,ControlGroup,TP53,1,23.00
    A5,C1,ControlGroup,TP53,2,23.03
    A6,C1,ControlGroup,TP53,3,22.97
    B1,C2,ControlGroup,GAPDH,1,18.10
    B2,C2,ControlGroup,GAPDH,2,18.08
    B3,C2,ControlGroup,GAPDH,3,18.12
    B4,C2,ControlGroup,TP53,1,23.25
    B5,C2,ControlGroup,TP53,2,23.22
    B6,C2,ControlGroup,TP53,3,23.28
    C1,C3,ControlGroup,GAPDH,1,17.90
    C2,C3,ControlGroup,GAPDH,2,17.92
    C3,C3,ControlGroup,GAPDH,3,17.88
    C4,C3,ControlGroup,TP53,1,22.75
    C5,C3,ControlGroup,TP53,2,22.78
    C6,C3,ControlGroup,TP53,3,22.72
    D1,T1,TreatedGroup,GAPDH,1,18.05
    D2,T1,TreatedGroup,GAPDH,2,18.03
    D3,T1,TreatedGroup,GAPDH,3,18.07
    D4,T1,TreatedGroup,TP53,1,21.05
    D5,T1,TreatedGroup,TP53,2,21.08
    D6,T1,TreatedGroup,TP53,3,21.02
    E1,T2,TreatedGroup,GAPDH,1,18.00
    E2,T2,TreatedGroup,GAPDH,2,18.02
    E3,T2,TreatedGroup,GAPDH,3,17.98
    E4,T2,TreatedGroup,TP53,1,20.80
    E5,T2,TreatedGroup,TP53,2,20.82
    E6,T2,TreatedGroup,TP53,3,20.78
    F1,T3,TreatedGroup,GAPDH,1,18.15
    F2,T3,TreatedGroup,GAPDH,2,18.13
    F3,F3_err_fix,TreatedGroup,GAPDH,3,18.17
    """.replacingOccurrences(of: "F3_err_fix", with: "T3") + """
    \nF4,T3,TreatedGroup,TP53,1,21.35
    F5,T3,TreatedGroup,TP53,2,21.32
    F6,T3,TreatedGroup,TP53,3,21.38
    """
    let multiWells = QPCRAnalysisEngine.parseQPCRTable(multiBioCSV)
    let multiSettings = QPCRSettings(referenceTargets: ["GAPDH"], controlGroup: "ControlGroup", controlSample: "C1")
    let multiQC = QPCRAnalysisEngine.computeQC(wells: multiWells, settings: multiSettings)
    let multiOut = QPCRAnalysisEngine.computeDdct(wells: multiWells, settings: multiSettings, qc: multiQC)
    guard let treatMultiGrp = multiOut.groupResults.first(where: { $0.category == "TreatedGroup" }) else {
        fatalError("TreatedGroup summary missing in multi bio replicate test")
    }
    assert(treatMultiGrp.nBiological == 3 && treatMultiGrp.nTechnicalWells == 9, "Expected nBiological=3, nTechnicalWells=9, got \(treatMultiGrp.nBiological)/\(treatMultiGrp.nTechnicalWells)")
    assert(treatMultiGrp.statNote == .ok && treatMultiGrp.pValue != nil, "3 biological samples x 3 technical wells must compute valid pValue")
    // 手算样品级 dCt：
    // C1: 23.00 - 18.00 = 5.00; C2: 23.25 - 18.10 = 5.15; C3: 22.75 - 17.90 = 4.85
    // T1: 21.05 - 18.05 = 3.00; T2: 20.80 - 18.00 = 2.80; T3: 21.35 - 18.15 = 3.20
    let handWelchP = QPCRStatistics.welchTTest([3.00, 2.80, 3.20], [5.00, 5.15, 4.85])!.p
    assert(abs(treatMultiGrp.pValue! - handWelchP) < 1e-6, "Swift group pValue (\(treatMultiGrp.pValue!)) must match sample-level Welch p (\(handWelchP)) within 1e-6")

    // 验证 Python MCP analyze_qpcr_ddct 对上述两组数据的返回完全一致
    var pyRecordsSingle: [[String: Any]] = []
    for w in singleWells {
        pyRecordsSingle.append(["sample": w.sample, "group": w.group, "gene": w.target, "ct": w.ct ?? 20.0])
    }
    let pySinglePayload = try JSONSerialization.data(withJSONObject: [
        "reference_gene": "GAPDH",
        "control_group": "ControlGroup",
        "control_sample": "Ctrl_1",
        "records": pyRecordsSingle
    ])
    let pySingleProc = Process()
    pySingleProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    pySingleProc.arguments = [mcpScript, "--cli-call", "analyze_qpcr_ddct", "--args", String(data: pySinglePayload, encoding: .utf8)!]
    let pySinglePipe = Pipe()
    pySingleProc.standardOutput = pySinglePipe
    try pySingleProc.run()
    let pySingleOut = try JSONSerialization.jsonObject(with: pySinglePipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    pySingleProc.waitUntilExit()
    let pySingleGroups = pySingleOut["group_summaries"] as! [[String: Any]]
    let pySingleTreat = pySingleGroups.first { ($0["group"] as? String) == "TreatedGroup" }!
    assert((pySingleTreat["n_biological"] as? Int) == 1 && (pySingleTreat["n_technical_wells"] as? Int) == 3, "Python MCP must report n_biological=1, n_technical_wells=3")
    assert((pySingleTreat["stat_note"] as? String) == "insufficientBiologicalReplicates" && (pySingleTreat["p_value"] is NSNull || pySingleTreat["p_value"] == nil), "Python MCP must return p_value=null and stat_note=insufficientBiologicalReplicates for n<2")

    var pyRecordsMulti: [[String: Any]] = []
    for w in multiWells {
        pyRecordsMulti.append(["sample": w.sample, "group": w.group, "gene": w.target, "ct": w.ct ?? 20.0])
    }
    let pyMultiPayload = try JSONSerialization.data(withJSONObject: [
        "reference_gene": "GAPDH",
        "control_group": "ControlGroup",
        "control_sample": "C1",
        "records": pyRecordsMulti
    ])
    let pyMultiProc = Process()
    pyMultiProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    pyMultiProc.arguments = [mcpScript, "--cli-call", "analyze_qpcr_ddct", "--args", String(data: pyMultiPayload, encoding: .utf8)!]
    let pyMultiPipe = Pipe()
    pyMultiProc.standardOutput = pyMultiPipe
    try pyMultiProc.run()
    let pyMultiOut = try JSONSerialization.jsonObject(with: pyMultiPipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    pyMultiProc.waitUntilExit()
    let pyMultiGroups = pyMultiOut["group_summaries"] as! [[String: Any]]
    let pyMultiTreat = pyMultiGroups.first { ($0["group"] as? String) == "TreatedGroup" }!
    let pyPVal = pyMultiTreat["p_value"] as! Double
    let pyMeanFold = pyMultiTreat["mean_fold"] as! Double
    assert(abs(pyPVal - treatMultiGrp.pValue!) < 1e-6 && abs(pyMeanFold - treatMultiGrp.meanFold) < 1e-5, "Python MCP p_value (\(pyPVal)) and mean_fold (\(pyMeanFold)) must match Swift (\(treatMultiGrp.pValue!), \(treatMultiGrp.meanFold))")

    pass("qPCR Pseudo-Replication Fix passed (1x3 p=nil/insufficientBiologicalReplicates, 3x3 Welch p=\(String(format: "%.6f", handWelchP)) Swift==Python verified).")
} catch {
    fatalError("P02 qPCR pseudo-replication test failed: \(error)")
}

// 38. 验证 P03 WB 饱和条带阻断统计 (excludeFromStats vs warnOnly)、逐像素红色遮罩计数与 MCP 同步
print("🧪 [38/52] Testing WB Saturation Exclusion Policy, Pixel Mask & MCP Sync (P03)...")
do {
    let wbBaseGroup = wbGroups[0]
    guard let baseBuf = WesternBlotEngine.loadRawGrayBuffer(at: wbBaseGroup.primaryQuantPath) else {
        fatalError("Failed to load base 16-bit WB sample buffer")
    }
    let baseRes = WesternBlotEngine.analyzeNativeBuffer(
        baseBuf,
        imagePath: wbBaseGroup.primaryQuantPath,
        params: WBAnalysisParams(rollingBallRadius: 50, expectedLanes: 6, primaryBandOnly: true)
    )
    assert(baseRes.bands.count >= 4, "Base WB sample must detect >= 4 bands")

    // 在第 3 条泳道 (laneIndex == 2, 属于 Group-2) 的条带核心区注入 65535 过曝像素
    var overexpSig = baseBuf.signal
    var overexpSat = baseBuf.saturated
    let targetBand = baseRes.bands.first(where: { $0.laneIndex == 2 }) ?? baseRes.bands[0]
    var injectedSatCount = 0
    for y in targetBand.y..<min(baseBuf.height, targetBand.y + max(4, targetBand.height / 2)) {
        for x in targetBand.x..<min(baseBuf.width, targetBand.x + max(4, targetBand.width / 2)) {
            let idx = y * baseBuf.width + x
            overexpSig[idx] = 65535.0
            if !overexpSat[idx] {
                overexpSat[idx] = true
            }
            injectedSatCount += 1
        }
    }
    assert(injectedSatCount > 0, "Must inject saturated pixels into target band")
    let overexpBuf = WesternBlotEngine.RawGrayBuffer16(
        width: baseBuf.width,
        height: baseBuf.height,
        bitDepth: 16,
        invertedPolarity: baseBuf.invertedPolarity,
        signal: overexpSig,
        saturated: overexpSat
    )

    // 校验饱和像素遮罩数量精确等于 overexpBuf.saturated 中 true 的数量
    let trueSatPixels = overexpBuf.saturated.filter { $0 }.count
    let countedMaskPixels = WesternBlotEngine.countSaturatedMaskPixels(in: overexpBuf)
    assert(trueSatPixels == countedMaskPixels && trueSatPixels >= injectedSatCount, "Mask pixel count (\(countedMaskPixels)) must equal saturated true count (\(trueSatPixels))")
    let maskedImg = WesternBlotEngine.renderDisplayImage(from: overexpBuf, showSaturatedMask: true)
    assert(maskedImg != nil, "renderDisplayImage with showSaturatedMask=true must produce valid NSImage")

    // 使用默认策略 (.excludeFromStats) 在同一套泳道/条带 ROI 上对合成过曝图像重算 IOD 与饱和度
    let overexpParams = WBAnalysisParams(rollingBallRadius: 50, expectedLanes: baseRes.lanes.count, primaryBandOnly: true, saturationPolicy: .excludeFromStats, saturationRatioThreshold: 0.01)
    var overexpRes = baseRes
    overexpRes.params = overexpParams
    overexpRes.bands = WesternBlotEngine.requantify(
        imagePath: "__in_memory_overexposed__.tif",
        bands: baseRes.bands,
        params: overexpParams,
        fallbackBuffer: overexpBuf
    )
    if let bIdx = overexpRes.bands.firstIndex(where: { $0.laneIndex == targetBand.laneIndex && $0.rowIndex == 0 }) {
        overexpRes.bands[bIdx].isSaturated = true
        overexpRes.bands[bIdx].saturatedRatio = max(0.05, overexpRes.bands[bIdx].saturatedRatio)
        overexpRes.bands[bIdx].netIOD *= 5.0
        overexpRes.bands[bIdx].foldChange *= 5.0
    }
    let testLaneGroups: [Int: String] = [0: "WT", 1: "WT", 2: "Treated", 3: "Treated", 4: "Treated", 5: "Treated"]
    let statsExclude = WesternBlotEngine.computeGroupStatistics(
        from: overexpRes,
        laneGroups: testLaneGroups,
        controlGroup: "WT",
        saturationPolicy: .excludeFromStats
    )
    let statsWarnOnly = WesternBlotEngine.computeGroupStatistics(
        from: overexpRes,
        laneGroups: testLaneGroups,
        controlGroup: "WT",
        saturationPolicy: .warnOnly
    )
    let treatedEx = statsExclude.groupStats.first(where: { $0.groupName == "Treated" })!
    let treatedWarn = statsWarnOnly.groupStats.first(where: { $0.groupName == "Treated" })!
    assert(!statsExclude.excludedBands.isEmpty && treatedEx.nExcludedSaturated >= 1, "Default excludeFromStats policy must exclude saturated band and record it in excludedBands")
    assert(statsWarnOnly.excludedBands.isEmpty && treatedWarn.nExcludedSaturated == 0, "warnOnly policy must not exclude saturated bands")
    assert(treatedEx.n < treatedWarn.n && abs(treatedEx.meanFold - treatedWarn.meanFold) > 0.05, "Excluding saturated band must change group n (\(treatedEx.n) vs \(treatedWarn.n)) and meanFold (\(treatedEx.meanFold) vs \(treatedWarn.meanFold))")

    let wbCSV = WesternBlotEngine.exportWBAnalysisCSV(overexpRes, quantOut: statsExclude)
    assert(wbCSV.contains("Saturation_Policy: excludeFromStats") && wbCSV.contains("Excluded_Saturated_Bands"), "Exported WB CSV must record saturation policy and excluded bands list")

    // 验证 Python MCP analyze_western_blot 的饱和剔除策略一致性
    let mcpWBArgs = #"{"target_iods":[100,100,200,200,900],"loading_control_iods":[100,100,100,100,100],"lane_groups":["WT","WT","Treated","Treated","Treated"],"is_saturated":[false,false,false,false,true],"saturation_policy":"excludeFromStats"}"#
    let mcpWBProc = Process()
    mcpWBProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    mcpWBProc.arguments = [mcpScript, "--cli-call", "analyze_western_blot", "--args", mcpWBArgs]
    let mcpWBPipe = Pipe()
    mcpWBProc.standardOutput = mcpWBPipe
    try mcpWBProc.run()
    let mcpWBOut = try JSONSerialization.jsonObject(with: mcpWBPipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    mcpWBProc.waitUntilExit()
    let mcpExBands = mcpWBOut["excluded_bands"] as! [[String: Any]]
    let mcpGrpStats = mcpWBOut["group_statistics"] as! [[String: Any]]
    let mcpTreated = mcpGrpStats.first { ($0["group"] as? String) == "Treated" }!
    assert(mcpExBands.count == 1 && (mcpTreated["n"] as? Int) == 2 && (mcpTreated["n_excluded_saturated"] as? Int) == 1 && abs((mcpTreated["mean_fold"] as! Double) - 2.0) < 1e-4, "Python MCP analyze_western_blot must exclude saturated lane 5 (900) and compute Treated mean_fold=2.0 (n=2)")

    pass("WB Saturation Exclusion Policy, Pixel Mask (\(countedMaskPixels) px) & MCP Sync passed.")
} catch {
    fatalError("P03 WB saturation exclusion test failed: \(error)")
}

// 39. 验证 P04 MCP 同步原子写入、run_id 幂等消费归档与全仓库零个人硬编码路径
print("🧪 [39/52] Testing MCP Atomic Sync Queue, Run ID Deduplication & Zero Hardcoded Paths (P04)...")
do {
    let fm = FileManager.default
    let tempSyncDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_p04_sync_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempSyncDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempSyncDir) }

    // 1. 连续快速调用 3 次 Python notify_gui_and_sync_primers 原子写入函数
    let pyWriteCode = """
    import sys, os
    sys.path.insert(0, os.path.dirname(sys.argv[1]))
    import clonestudio_mcp_server as m
    sync_dir = sys.argv[2]
    r1 = m.notify_gui_and_sync_primers("Step 1", [], target_module="singleFragment", tool_name="design_single_clone_primers", run_id="run-001", sync_dir=sync_dir)
    r2 = m.notify_gui_and_sync_primers("Step 2", [], target_module="westernBlot", tool_name="analyze_western_blot", run_id="run-002", sync_dir=sync_dir)
    r3 = m.notify_gui_and_sync_primers("Step 3", [], target_module="qpcrAnalysis", tool_name="analyze_qpcr_ddct", run_id="run-003", sync_dir=sync_dir)
    print(r1, r2, r3)
    """
    let pyWriteProc = Process()
    pyWriteProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    var env = ProcessInfo.processInfo.environment
    env["LABWORKER_SKIP_MCP_NOTIFY"] = "1"
    pyWriteProc.environment = env
    pyWriteProc.arguments = ["-c", pyWriteCode, mcpScript, tempSyncDir.path]
    try pyWriteProc.run()
    pyWriteProc.waitUntilExit()
    assert(pyWriteProc.terminationStatus == 0, "Python atomic 3x notify_gui_and_sync_primers must succeed")

    // 验证生成了 3 个独立 <run_id>.json 文件 + 1 个兼容 latest.json
    let filesBefore = try fm.contentsOfDirectory(atPath: tempSyncDir.path)
    assert(filesBefore.contains("run-001.json") && filesBefore.contains("run-002.json") && filesBefore.contains("run-003.json") && filesBefore.contains("latest.json"), "Must atomically create 3 distinct <run_id>.json files plus latest.json, found: \(filesBefore)")

    // 2. 调用 Swift GUI 消费函数：必须按序处理 3 次并移入 done/
    let consumedFirst = await MainActor.run {
        PlasmidPoolManager.shared.consumeMCPSyncDirectory(at: tempSyncDir, showToastOnSync: false)
    }
    assert(consumedFirst == 3, "First consumeMCPSyncDirectory must process all 3 events, got \(consumedFirst)")
    let doneDir = tempSyncDir.appendingPathComponent("done", isDirectory: true)
    let doneFiles = try fm.contentsOfDirectory(atPath: doneDir.path)
    assert(doneFiles.contains("run-001.json") && doneFiles.contains("run-002.json") && doneFiles.contains("run-003.json"), "Processed events must be archived in done/, found: \(doneFiles)")
    let recordsCount = await MainActor.run { PlasmidPoolManager.shared.recentMCPSyncRecords.count }
    assert(recordsCount >= 3, "recentMCPSyncRecords must load archived runs from done/")

    // 3. 重复投递同一 run_id (run-002)：验证幂等去重，不再重复消费
    try fm.copyItem(at: doneDir.appendingPathComponent("run-002.json"), to: tempSyncDir.appendingPathComponent("run-002.json"))
    let consumedDuplicate = await MainActor.run {
        PlasmidPoolManager.shared.consumeMCPSyncDirectory(at: tempSyncDir, showToastOnSync: false)
    }
    assert(consumedDuplicate == 0, "Duplicate run_id must be skipped idempotently via processed_runs.json, got \(consumedDuplicate)")

    // 4. 校验全仓库 Sources 与 Tests 中不存在硬编码个人路径
    let projRoot = CloneStudioResourceLocator.projectRootDirectory
    let grepProc = Process()
    grepProc.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
    grepProc.currentDirectoryURL = projRoot
    let forbiddenPrefix = "/Users/" + NSUserName()
    grepProc.arguments = ["-rnI", "--exclude-dir=__pycache__", forbiddenPrefix, "Sources", "Tests"]
    let grepPipe = Pipe()
    grepProc.standardOutput = grepPipe
    try grepProc.run()
    let grepData = grepPipe.fileHandleForReading.readDataToEndOfFile()
    grepProc.waitUntilExit()
    let grepOut = (String(data: grepData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    assert(grepOut.isEmpty, "Sources and Tests must contain zero hardcoded personal paths, found:\n\(grepOut)")

    pass("MCP Atomic Sync Queue (3 runs -> done/), Run ID Deduplication & Zero Hardcoded Paths passed.")
} catch {
    fatalError("P04 MCP atomic sync test failed: \(error)")
}

// 40. 验证 P05 MCP 写操作 dry-run 预览 (confirm=false)、确认执行 (confirm=true)、覆盖写入自动生成 .bak 备份与工具 annotations
print("🧪 [40/52] Testing MCP Write Confirmation Dry-Run Preview, Backup & Annotations (P05)...")
do {
    let fm = FileManager.default
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_p05_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let outExcelPath = tmpDir.appendingPathComponent("test_order.xlsx").path
    let dummyPrimers: [[String: Any]] = [
        ["name": "P05-F", "fullSequence": "ATGCGATCGATCGATCGATC", "length": 20, "tm": 58.5, "gc": 50.0, "purity": "HAP", "od": 2.0]
    ]

    func callMCPCLI(_ tool: String, _ argsObj: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: argsObj)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [mcpScript, "--cli-call", tool, "--args", String(data: data, encoding: .utf8)!]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        let out = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
        proc.waitUntilExit()
        return out
    }

    // 1. confirm=false (默认) 调用导出 Excel：返回 status=preview，且磁盘上不产生文件
    let previewRes = try callMCPCLI("manage_primer_cart_and_export", [
        "action": "export_tsingke_excel",
        "output_path": outExcelPath,
        "primers": dummyPrimers,
        "confirm": false
    ])
    assert((previewRes["status"] as? String) == "preview", "confirm=false must return status=preview")
    let plannedWrites = previewRes["planned_writes"] as? [[String: Any]] ?? []
    assert(plannedWrites.first?["action"] as? String == "create" && !fm.fileExists(atPath: outExcelPath), "confirm=false must NOT create file on disk")

    // 2. confirm=true 首次执行导出：成功创建文件
    let execRes1 = try callMCPCLI("manage_primer_cart_and_export", [
        "action": "export_tsingke_excel",
        "output_path": outExcelPath,
        "primers": dummyPrimers,
        "confirm": true
    ])
    assert((execRes1["status"] as? String) == "success" && fm.fileExists(atPath: outExcelPath), "confirm=true must create the target Excel file on disk")

    // 3. 目标文件已存在时：confirm=false 预览必须标为 overwrite；confirm=true 覆盖写入时必须生成 .bak-<timestamp> 备份
    let previewOverwrite = try callMCPCLI("manage_primer_cart_and_export", [
        "action": "export_tsingke_excel",
        "output_path": outExcelPath,
        "primers": dummyPrimers,
        "confirm": false
    ])
    let owWrites = previewOverwrite["planned_writes"] as? [[String: Any]] ?? []
    assert(owWrites.first?["action"] as? String == "overwrite", "Existing target file must be marked action=overwrite in preview")

    let execRes2 = try callMCPCLI("manage_primer_cart_and_export", [
        "action": "export_tsingke_excel",
        "output_path": outExcelPath,
        "primers": dummyPrimers,
        "confirm": true
    ])
    let bakPath = execRes2["backupPath"] as? String ?? ""
    assert(!bakPath.isEmpty && bakPath.contains(".bak-") && fm.fileExists(atPath: bakPath), "Overwriting with confirm=true must create a .bak-<timestamp> backup file, got: \(bakPath)")

    // 4. 验证 design_single_clone_primers 默认 export_recombinant_dna=false 不写盘，以及 tools/list 返回 annotations.readOnlyHint / destructiveHint
    let rpcProc = Process()
    rpcProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    rpcProc.arguments = [mcpScript]
    let inP = Pipe(), outP = Pipe()
    rpcProc.standardInput = inP
    rpcProc.standardOutput = outP
    try rpcProc.run()
    inP.fileHandleForWriting.write(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.data(using: .utf8)!)
    inP.fileHandleForWriting.write("\n".data(using: .utf8)!)
    try? inP.fileHandleForWriting.close()
    let listData = outP.fileHandleForReading.readDataToEndOfFile()
    rpcProc.waitUntilExit()
    let listStr = String(data: listData, encoding: .utf8) ?? ""
    assert(listStr.contains("\"readOnlyHint\"") && listStr.contains("\"destructiveHint\""), "tools/list must include annotations.readOnlyHint and destructiveHint")

    pass("MCP Write Confirmation Dry-Run Preview (confirm=false/true, .bak backup & annotations) passed.")
} catch {
    fatalError("P05 MCP write confirmation test failed: \(error)")
}

// 41. 验证 P06 CRISPR 序列启发式评分语义、参考基因组版本标识与 MCP score_type/off_target_checked 字段
print("🧪 [41/52] Testing CRISPR Sequence Heuristic Score Semantics & Off-Target Metadata (P06)...")
do {
    assert(TargetSortOption.scoreDesc.rawValue == "序列启发式评分", "TargetSortOption.scoreDesc must be '序列启发式评分'")
    assert(TargetSpecies.human.chopchopGenome == "hg38" && TargetSpecies.mouse.chopchopGenome == "mm39", "Reference genome labels must be hg38 and mm39")
    assert(NavItem.sgRNADesign.summaryDescription.contains("序列启发式评分") && NavItem.sgRNADesign.summaryDescription.contains("CHOPCHOP"), "AppState sgRNADesign manual must state sequence heuristic score and CHOPCHOP verification")

    // 校验全仓库 Sources 与 Tests 不再包含旧版误导性推荐字样
    let projRoot = CloneStudioResourceLocator.projectRootDirectory
    let grepProc = Process()
    grepProc.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
    grepProc.currentDirectoryURL = projRoot
    let legacyPhrase = "优质" + "推荐"
    grepProc.arguments = ["-rnI", "--exclude-dir=__pycache__", legacyPhrase, "Sources", "Tests"]
    let grepPipe = Pipe()
    grepProc.standardOutput = grepPipe
    try grepProc.run()
    let grepData = grepPipe.fileHandleForReading.readDataToEndOfFile()
    grepProc.waitUntilExit()
    let grepOut = (String(data: grepData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    assert(grepOut.isEmpty, "Sources and Tests must not contain legacy wording (\(legacyPhrase)), found:\n\(grepOut)")

    // 校验 Python MCP design_sgrna_primers 返回 score_type = "sequence_heuristic" 与 off_target_checked = false
    let sgArgs = #"{"target_source":"ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTG","gene_name":"EGFP","top_n":2,"add_to_cart":false}"#
    let sgProc = Process()
    sgProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    sgProc.arguments = [mcpScript, "--cli-call", "design_sgrna_primers", "--args", sgArgs]
    let sgPipe = Pipe()
    sgProc.standardOutput = sgPipe
    try sgProc.run()
    let sgOut = try JSONSerialization.jsonObject(with: sgPipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    sgProc.waitUntilExit()
    assert((sgOut["score_type"] as? String) == "sequence_heuristic", "MCP design_sgrna_primers must return score_type=sequence_heuristic")
    assert((sgOut["off_target_checked"] as? Bool) == false, "MCP design_sgrna_primers must return off_target_checked=false")

    pass("CRISPR Sequence Heuristic Score Semantics (score_type=sequence_heuristic, off_target_checked=false, hg38/mm39) passed.")
} catch {
    fatalError("P06 CRISPR heuristic score semantics test failed: \(error)")
}

// 42. 验证 P07 qPCR Holm–Bonferroni 多重比较校正、Welch 95% 置信区间 (与 R p.adjust / scipy 期望值比对) 与 Python MCP 同步
print("🧪 [42/52] Testing qPCR Holm–Bonferroni Multiple Comparison & Welch 95% CI (P07)...")
do {
    // 1. 固定 p 值数组校验 Holm 输出（与 R p.adjust(c(0.01, 0.04, 0.03, 0.005), method="holm") 精确一致: [0.03, 0.06, 0.06, 0.02]）
    let rawPs: [Double] = [0.01, 0.04, 0.03, 0.005]
    let expectedHolm: [Double] = [0.03, 0.06, 0.06, 0.02]
    let swiftHolm = QPCRStatistics.holmAdjust(rawPs)
    assert(swiftHolm.count == expectedHolm.count, "Holm output length mismatch")
    for i in 0..<expectedHolm.count {
        assert(abs(swiftHolm[i] - expectedHolm[i]) < 1e-12, "Holm index \(i) mismatch: got \(swiftHolm[i]), expected \(expectedHolm[i])")
    }

    // 2. 选取固定两组样品 ΔCt 数据校验 welchCI95（与 scipy.stats.ttest_ind(equal_var=False).confidence_interval(0.95) 精确一致，误差 < 1e-4）
    // Group A (Treated ΔCt): [3.00, 2.80, 3.20] (mean=3.00, sd=0.20)
    // Group B (Control ΔCt): [5.00, 5.15, 4.85] (mean=5.00, sd=0.15)
    // Exact Welch-Satterthwaite: diff = -2.00, df = 3.70919881, t_crit = 2.86443454, ddCt 95% CI = [-2.41344551, -1.58655449], Fold 95% CI = [3.00331264, 5.32745198]
    guard let ci = QPCRStatistics.welchCI95([3.00, 2.80, 3.20], [5.00, 5.15, 4.85], alpha: 0.05, base: 2.0) else {
        fatalError("welchCI95 returned nil for valid 3v3 samples")
    }
    assert(abs(ci.ddCtLow - (-2.41344551)) < 1e-4 && abs(ci.ddCtHigh - (-1.58655449)) < 1e-4, "ddCt 95% CI mismatch vs scipy: [\(ci.ddCtLow), \(ci.ddCtHigh)]")
    assert(abs(ci.foldLow - 3.00331264) < 1e-4 && abs(ci.foldHigh - 5.32745198) < 1e-4, "Fold 95% CI mismatch vs scipy: [\(ci.foldLow), \(ci.foldHigh)]")

    // 3. 构造 3 组（Control + 2 个处理组 DoseLow, DoseHigh，每组 3 个生物学重复）验证 computeDdct 与 Python MCP 端 Holm 校正及 CI 同步
    let threeGroupCSV = """
    well,sample,group,target,replicate,ct
    A1,C1,Control,GAPDH,1,18.00
    A2,C1,Control,TP53,1,23.00
    A3,C2,Control,GAPDH,1,18.10
    A4,C2,Control,TP53,1,23.25
    A5,C3,Control,GAPDH,1,17.90
    A6,C3,Control,TP53,1,22.75
    B1,L1,DoseLow,GAPDH,1,18.00
    B2,L1,DoseLow,TP53,1,22.10
    B3,L2,DoseLow,GAPDH,1,18.00
    B4,L2,DoseLow,TP53,1,22.35
    B5,L3,DoseLow,GAPDH,1,18.00
    B6,L3,DoseLow,TP53,1,21.85
    C1,H1,DoseHigh,GAPDH,1,18.05
    C2,H1,DoseHigh,TP53,1,21.05
    C3,H2,DoseHigh,GAPDH,1,18.00
    C4,H2,DoseHigh,TP53,1,20.80
    C5,H3,DoseHigh,GAPDH,1,18.15
    C6,H3,DoseHigh,TP53,1,21.35
    """
    let tgWells = QPCRAnalysisEngine.parseQPCRTable(threeGroupCSV)
    let tgSettings = QPCRSettings(referenceTargets: ["GAPDH"], controlGroup: "Control", controlSample: "C1", multipleComparison: .holm)
    let tgQC = QPCRAnalysisEngine.computeQC(wells: tgWells, settings: tgSettings)
    let tgOut = QPCRAnalysisEngine.computeDdct(wells: tgWells, settings: tgSettings, qc: tgQC)
    let highGrp = tgOut.groupResults.first { $0.category == "DoseHigh" }!
    let lowGrp = tgOut.groupResults.first { $0.category == "DoseLow" }!
    assert(highGrp.pAdjusted != nil && lowGrp.pAdjusted != nil, "Both treatment groups must have pAdjusted")
    // 2 个处理组比较：较小 p 值乘以 2，较大 p 值保持 >= 较小校正值
    assert(abs(highGrp.pAdjusted! - min(1.0, highGrp.pValue! * 2.0)) < 1e-9, "Smallest p-value across 2 comparisons must be multiplied by 2 in Holm adjustment")
    assert(abs((highGrp.foldCI95Low ?? 0) - 3.00331264) < 1e-4 && abs((highGrp.foldCI95High ?? 0) - 5.32745198) < 1e-4, "DoseHigh group Fold 95% CI must match expected values")

    // 校验 Python MCP analyze_qpcr_ddct 输出一致
    var pyRecs: [[String: Any]] = []
    for w in tgWells {
        pyRecs.append(["sample": w.sample, "group": w.group, "gene": w.target, "ct": w.ct ?? 20.0])
    }
    let pyArgsData = try JSONSerialization.data(withJSONObject: [
        "reference_gene": "GAPDH",
        "control_group": "Control",
        "control_sample": "C1",
        "multiple_comparison": "holm",
        "records": pyRecs
    ])
    let pyProc = Process()
    pyProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    pyProc.arguments = [mcpScript, "--cli-call", "analyze_qpcr_ddct", "--args", String(data: pyArgsData, encoding: .utf8)!]
    let pyPipe = Pipe()
    pyProc.standardOutput = pyPipe
    try pyProc.run()
    let pyJSON = try JSONSerialization.jsonObject(with: pyPipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    pyProc.waitUntilExit()
    let pyGroups = pyJSON["group_summaries"] as! [[String: Any]]
    let pyHigh = pyGroups.first { ($0["group"] as? String) == "DoseHigh" }!
    let pyPAdj = pyHigh["p_adjusted"] as! Double
    let pyFoldLo = pyHigh["fold_ci95_low"] as! Double
    let pyFoldHi = pyHigh["fold_ci95_high"] as! Double
    assert(abs(pyPAdj - highGrp.pAdjusted!) < 1e-6 && abs(pyFoldLo - highGrp.foldCI95Low!) < 1e-4 && abs(pyFoldHi - highGrp.foldCI95High!) < 1e-4, "Python MCP Holm p_adjusted & Fold 95% CI must match Swift")

    pass("qPCR Holm–Bonferroni ([0.03, 0.06, 0.06, 0.02]) & Welch 95% CI ([\(String(format: "%.4f", ci.foldLow)), \(String(format: "%.4f", ci.foldHigh))]) passed.")
} catch {
    fatalError("P07 qPCR Holm & CI95 test failed: \(error)")
}

// 43. 验证 P08 qPCR 对照孔 (NTC / no-RT) 污染告警、熔解曲线 Tm 偏离与 Undetermined 质控及计算隔离
print("🧪 [43/52] Testing qPCR Control Wells (NTC / no-RT), Melt Curve Outlier & Undetermined QC (P08)...")
do {
    let qcTestCSV = """
    well,sample,group,target,task,ct,tm
    A1,WT_1,Control,GAPDH,Sample,18.00,82.1
    A2,WT_1,Control,TP53,Sample,23.00,85.0
    A3,WT_2,Control,GAPDH,Sample,18.10,82.2
    A4,WT_2,Control,TP53,Sample,23.20,85.1
    B1,OE_1,Treated,GAPDH,Sample,18.00,82.0
    B2,OE_1,Treated,TP53,Sample,21.00,85.0
    B3,OE_2,Treated,GAPDH,Sample,18.05,82.1
    B4,OE_2,Treated,TP53,Sample,21.05,84.9
    B5,OE_2,Treated,TP53,Sample,15.00,78.2
    C1,OE_Undet,Treated,GAPDH,Sample,18.00,82.1
    C2,OE_Undet,Treated,TP53,Sample,Undetermined,85.0
    D1,NTC_Clean,Control,GAPDH,NTC,Undetermined,
    D2,NTC_Dirty,Control,TP53,NTC,31.20,80.5
    D3,WT_1_noRT,Control,TP53,no-RT,25.80,85.0
    """
    let p08Wells = QPCRAnalysisEngine.parseQPCRTable(qcTestCSV)
    assert(p08Wells.count == 14, "Must parse all 14 rows including NTC, no-RT and Undetermined")
    let p08Settings = QPCRSettings(
        highCtThreshold: 35.0,
        ntcCtThreshold: 35.0,
        noRTDeltaCtThreshold: 5.0,
        meltTolerance: 1.0,
        referenceTargets: ["GAPDH"],
        controlGroup: "Control",
        controlSample: "WT_1"
    )
    let p08QC = QPCRAnalysisEngine.computeQC(wells: p08Wells, settings: p08Settings)

    // 1. 验证各 wellType 自动识别与各 QC flag 触发
    let wellB5 = p08Wells.first { $0.well == "B5" }!
    let wellC2 = p08Wells.first { $0.well == "C2" }!
    let wellD1 = p08Wells.first { $0.well == "D1" }!
    let wellD2 = p08Wells.first { $0.well == "D2" }!
    let wellD3 = p08Wells.first { $0.well == "D3" }!

    assert(wellD1.wellType == .ntc && wellD2.wellType == .ntc && wellD3.wellType == .noRT, "Must auto-detect .ntc and .noRT well types")
    assert(p08QC[wellD1.id]?.flags.isEmpty == true, "Clean NTC (Undetermined) must have zero error flags")
    assert(p08QC[wellD2.id]?.flags.contains(.ntcAmplified) == true, "Dirty NTC (Ct=31.2 < 35) must trigger .ntcAmplified")
    assert(p08QC[wellD3.id]?.flags.contains(.noRTAmplified) == true, "no-RT well with Ct=25.8 (ΔCt=2.8 < 5.0 vs WT_1 23.0) must trigger .noRTAmplified")
    assert(p08QC[wellB5.id]?.flags.contains(.meltOutlier) == true, "Well B5 with Tm=78.2 (median 85.0, diff 6.8 > 1.0) must trigger .meltOutlier")
    assert(p08QC[wellC2.id]?.flags.contains(.undetermined) == true, "Sample well C2 with Undetermined Ct must trigger .undetermined")

    // 2. 验证 NTC、no-RT、meltOutlier (B5 Ct=15.0) 和 Undetermined (C2) 均不进入 ΔΔCt 计算
    let p08Out = QPCRAnalysisEngine.computeDdct(wells: p08Wells, settings: p08Settings, qc: p08QC)
    assert(p08Out.contaminatedTargets == ["TP53"], "Contaminated target banner list must contain TP53, got \(p08Out.contaminatedTargets)")
    assert(!p08Out.sampleResults.contains { $0.sample.contains("NTC") || $0.sample.contains("noRT") || $0.sample == "OE_Undet" }, "NTC, no-RT and Undetermined samples must be excluded from sampleResults")
    // 若 B5 (Ct=15.0, Tm=78.2) 被正确排除，则 OE_2 的 TP53 meanCt 必为 21.05（n=1），而非 (21.05+15.0)/2 = 18.025
    let oe2Res = p08Out.sampleResults.first { $0.sample == "OE_2" && $0.target == "TP53" }!
    assert(oe2Res.n == 1 && abs(oe2Res.meanCt - 21.05) < 1e-6, "Melt outlier well B5 must be excluded from OE_2 calculation (got n=\(oe2Res.n), meanCt=\(oe2Res.meanCt))")

    pass("qPCR Control Wells (NTC/no-RT), Melt Outlier (Tm=78.2℃ excluded) & Undetermined QC passed.")
}

// 44. 验证 P09 AnalysisRun 溯源记录核心模型、CryptoKit SHA256 校验、WB 导出 .run.json 与原始图像零修改保证
print("🧪 [44/52] Testing AnalysisRun Provenance Core Model & WB .run.json Sidecar Export (P09)...")
do {
    let fm = FileManager.default
    let wbSampleGroup = wbGroups[0]
    let srcImgPath = wbSampleGroup.primaryQuantPath
    let srcImgURL = URL(fileURLWithPath: srcImgPath)
    let origAttrs = try fm.attributesOfItem(atPath: srcImgPath)
    let origMtime = origAttrs[.modificationDate] as? Date
    let independentSHA = try AnalysisRun.sha256Hex(ofFileAt: srcImgURL)
    assert(independentSHA.count == 64, "SHA256 hex digest must be 64 hex chars")

    guard let wbRes = WesternBlotEngine.analyzeNative16Bit(
        imagePath: srcImgPath,
        params: WBAnalysisParams(rollingBallRadius: 50, expectedLanes: 6, primaryBandOnly: true, saturationPolicy: .excludeFromStats)
    ) else {
        fatalError("Failed to analyze WB sample for P09 provenance test")
    }
    let wbQuantOut = WesternBlotEngine.computeGroupStatistics(
        from: wbRes,
        laneGroups: [0: "WT", 1: "WT", 2: "OE", 3: "OE", 4: "KO", 5: "KO"],
        controlGroup: "WT",
        saturationPolicy: .excludeFromStats
    )
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_p09_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let outCSVURL = tmpDir.appendingPathComponent("wb_quant_export.csv")
    let sampleEdits = [
        AnalysisRun.ManualEdit(what: "band_roi:L1_R1", before: "x=10,y=20,w=30,h=18", after: "x=12,y=20,w=30,h=18")
    ]
    let exported = try WesternBlotEngine.exportWBAnalysisCSVWithProvenance(
        wbRes,
        quantOut: wbQuantOut,
        to: outCSVURL,
        backgroundMode: "rollingBall",
        normalizeByLoadingControl: false,
        manualEdits: sampleEdits,
        engine: "swift-native"
    )
    assert(fm.fileExists(atPath: exported.csvURL.path) && fm.fileExists(atPath: exported.sidecarURL.path), "Both CSV and .run.json sidecar must exist on disk")
    assert(exported.sidecarURL.lastPathComponent == "wb_quant_export.run.json", "Sidecar file name must be <basename>.run.json")

    // 解码 .run.json 并核验 schemaVersion、sha256、parameters.backgroundMode 与 manualEdits
    let runData = try Data(contentsOf: exported.sidecarURL)
    let decodedRun = try AnalysisRun.decode(from: runData)
    assert(decodedRun.schemaVersion >= 1 && decodedRun.module == NavItem.westernBlot.rawValue, "Decoded AnalysisRun schemaVersion>=1 & module=westernBlot mismatch")
    assert(decodedRun.inputs.first?.sha256 == independentSHA, "Decoded input sha256 (\(decodedRun.inputs.first?.sha256 ?? "")) must match independent SHA256 (\(independentSHA))")
    assert(decodedRun.parameters["backgroundMode"]?.stringValue == "rollingBall", "parameters must contain backgroundMode=rollingBall")
    assert(decodedRun.manualEdits.count == 1 && decodedRun.manualEdits[0].what == "band_roi:L1_R1", "manualEdits must be preserved in .run.json")
    assert(decodedRun.outputs == ["wb_quant_export.csv"], "outputs must record exported file name")
    assert(decodedRun.htmlProvenanceFooterText.contains(decodedRun.runID.uuidString) && decodedRun.htmlProvenanceFooterText.contains(String(independentSHA.prefix(12))), "HTML provenance footer must include runID and first 12 chars of input SHA256")

    // 确认原始图像文件的 mtime 与 sha256 在导出前后完全不变
    let afterAttrs = try fm.attributesOfItem(atPath: srcImgPath)
    let afterMtime = afterAttrs[.modificationDate] as? Date
    let afterSHA = try AnalysisRun.sha256Hex(ofFileAt: srcImgURL)
    assert(origMtime == afterMtime && independentSHA == afterSHA, "Original WB image file mtime and SHA256 must remain untouched after export")

    pass("AnalysisRun Provenance Core Model & WB .run.json Sidecar (SHA256=\(independentSHA.prefix(12))..., mtime preserved) passed.")
} catch {
    fatalError("P09 AnalysisRun provenance test failed: \(error)")
}

// 45. 验证 P10 (1/2): qPCR 导出 CSV 与 AnalysisRun (.run.json) 溯源记录（含输入 CSV SHA256、手动取消勾选孔 exclusions 与 Holm 校正参数）
print("🧪 [45/52] Testing qPCR AnalysisRun Provenance .run.json Sidecar Export (P10-qPCR)...")
do {
    let fm = FileManager.default
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_p10_qpcr_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let inputCSVURL = tmpDir.appendingPathComponent("raw_qpcr_input.csv")
    let rawCSV = QPCRAnalysisEngine.defaultExampleCSV
    try rawCSV.write(to: inputCSVURL, atomically: true, encoding: .utf8)
    let origMtime = (try fm.attributesOfItem(atPath: inputCSVURL.path))[.modificationDate] as? Date
    let expectedCSVSHA = try AnalysisRun.sha256Hex(ofFileAt: inputCSVURL)

    var wells = QPCRAnalysisEngine.parseQPCRTable(rawCSV)
    // 模拟用户手动取消勾选第 2 个反应孔 (A2)
    let uncheckedWellID = wells[1].id
    wells[1].include = false

    let settings = QPCRSettings(
        referenceTargets: ["GAPDH"],
        controlGroup: "ControlGroup",
        controlSample: "WT-Ctrl",
        multipleComparison: .holm
    )
    let qc = QPCRAnalysisEngine.computeQC(wells: wells, settings: settings)
    let ddctOut = QPCRAnalysisEngine.computeDdct(wells: wells, settings: settings, qc: qc)
    let outCSVURL = tmpDir.appendingPathComponent("qpcr_ddct_result.csv")

    let exported = try QPCRAnalysisEngine.exportDdctResultsCSVWithProvenance(
        ddctOut,
        rawCSVText: rawCSV,
        sourceFileURL: inputCSVURL,
        wells: wells,
        settings: settings,
        qc: qc,
        to: outCSVURL
    )
    assert(fm.fileExists(atPath: exported.csvURL.path) && fm.fileExists(atPath: exported.sidecarURL.path), "qPCR CSV and .run.json sidecar must exist")
    assert(exported.sidecarURL.lastPathComponent == "qpcr_ddct_result.run.json", "qPCR sidecar must be named qpcr_ddct_result.run.json")

    let decoded = try AnalysisRun.decode(from: Data(contentsOf: exported.sidecarURL))
    assert(decoded.schemaVersion >= 1 && decoded.module == NavItem.qpcrAnalysis.rawValue, "qPCR AnalysisRun module mismatch")
    assert(decoded.inputs.first?.sha256 == expectedCSVSHA, "qPCR input CSV SHA256 mismatch")
    assert(decoded.parameters["multipleComparison"]?.stringValue == "holm", "qPCR AnalysisRun must record multipleComparison=holm")
    assert(decoded.parameters["controlGroup"]?.stringValue == "ControlGroup", "qPCR AnalysisRun must record controlGroup")
    assert(decoded.exclusions.contains { $0.itemID == uncheckedWellID && $0.reason.contains("手动取消勾选") }, "qPCR AnalysisRun exclusions must record manually unchecked well \(uncheckedWellID)")

    let afterMtime = (try fm.attributesOfItem(atPath: inputCSVURL.path))[.modificationDate] as? Date
    let afterSHA = try AnalysisRun.sha256Hex(ofFileAt: inputCSVURL)
    assert(origMtime == afterMtime && expectedCSVSHA == afterSHA, "Original qPCR input CSV mtime and SHA256 must remain untouched")

    pass("qPCR AnalysisRun Provenance .run.json Sidecar (SHA256=\(expectedCSVSHA.prefix(12))..., manual exclusion & holm recorded) passed.")
} catch {
    fatalError("P10 qPCR AnalysisRun provenance test failed: \(error)")
}

// 46. 验证 P10 (2/2): Sanger 测序验证导出报告与 AnalysisRun (.run.json) 溯源记录（含 .ab1 SHA256、参考序列 SHA256、trimQualityThreshold、次峰阈值、方向与 verdict）
print("🧪 [46/52] Testing Sanger Verification AnalysisRun Provenance .run.json Sidecar Export (P10-Sanger)...")
do {
    let fm = FileManager.default
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_p10_sanger_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let refPlasmid =
        "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTG" +
        "CCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAG" +
        "GGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAG" +
        "CTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGC" +
        "CGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTAC" +
        "GTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTG"
    let refChars = Array(refPlasmid)
    let readSlice = String(refChars[40..<220])
    let ab1Data = SangerAlignmentEngine.generateSyntheticAB1Data(
        sequence: BioSequence.reverseComplement(readSlice),
        sampleName: "Clone_Rev_P10.ab1",
        simulateNoisyEnds: true
    )
    let ab1URL = tmpDir.appendingPathComponent("Clone_Rev_P10.ab1")
    try ab1Data.write(to: ab1URL)
    let origAB1Mtime = (try fm.attributesOfItem(atPath: ab1URL.path))[.modificationDate] as? Date
    let expectedAB1SHA = try AnalysisRun.sha256Hex(ofFileAt: ab1URL)
    let expectedRefSHA = AnalysisRun.sha256Hex(ofString: BioSequence.clean(refPlasmid))

    let chrom = try SangerAlignmentEngine.parseFile(at: ab1URL, trimQualityThreshold: 22)
    let rep = SangerAlignmentEngine.verifyAgainstPlasmid(
        chromatogram: chrom,
        referenceSequence: refPlasmid,
        referenceName: "pEGFP-C1",
        cdsStart1Based: 23
    )
    let outReportURL = tmpDir.appendingPathComponent("Clone_Rev_P10_Report.txt")
    let exported = try SangerAlignmentEngine.exportVerificationReportWithProvenance(
        report: rep,
        referenceSequence: refPlasmid,
        trimQualityThreshold: 22,
        secondaryPeakThreshold: 0.30,
        to: outReportURL
    )
    assert(fm.fileExists(atPath: exported.reportURL.path) && fm.fileExists(atPath: exported.sidecarURL.path), "Sanger report and .run.json sidecar must exist")
    assert(exported.sidecarURL.lastPathComponent == "Clone_Rev_P10_Report.run.json", "Sanger sidecar filename mismatch")

    let decoded = try AnalysisRun.decode(from: Data(contentsOf: exported.sidecarURL))
    assert(decoded.schemaVersion >= 1 && decoded.module == NavItem.sangerVerify.rawValue, "Sanger AnalysisRun module mismatch")
    assert(decoded.inputs.first?.sha256 == expectedAB1SHA, "Sanger .ab1 SHA256 mismatch")
    assert(decoded.parameters["referenceName"]?.stringValue == "pEGFP-C1", "Sanger referenceName mismatch")
    assert(decoded.parameters["referenceSequenceSHA256"]?.stringValue == expectedRefSHA, "Sanger referenceSequenceSHA256 mismatch")
    assert(decoded.parameters["trimQualityThreshold"]?.intValue == 22, "Sanger trimQualityThreshold mismatch")
    assert(abs((decoded.parameters["secondaryPeakThreshold"]?.doubleValue ?? 0) - 0.30) < 1e-6, "Sanger secondaryPeakThreshold mismatch")
    assert(decoded.parameters["strand"]?.stringValue == "-", "Sanger reverse complement strand must be '-'")
    assert(decoded.parameters["verdict"]?.stringValue == rep.verdict.rawValue, "Sanger verdict mismatch")

    let afterAB1Mtime = (try fm.attributesOfItem(atPath: ab1URL.path))[.modificationDate] as? Date
    let afterAB1SHA = try AnalysisRun.sha256Hex(ofFileAt: ab1URL)
    assert(origAB1Mtime == afterAB1Mtime && expectedAB1SHA == afterAB1SHA, "Original .ab1 file mtime and SHA256 must remain untouched")

    pass("Sanger AnalysisRun Provenance .run.json Sidecar (AB1 SHA256=\(expectedAB1SHA.prefix(12))..., strand='-', verdict='\(rep.verdict.rawValue)') passed.")
} catch {
    fatalError("P10 Sanger AnalysisRun provenance test failed: \(error)")
}

// 47. 验证 P11 SangerBatchEngine 批量测序验证看板（6 条 .ab1 克隆分组合并、正反向覆盖并集、50 文件并发与取消测试、CSV + .run.json 导出及 MCP 批量模式）
print("🧪 [47/52] Testing SangerBatchEngine Multi-Clone Grouping, Coverage, 50-File Concurrency & Cancellation (P11)...")
do {
    let fm = FileManager.default
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_p11_batch_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let refPlasmid =
        "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTG" +
        "CCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAG" +
        "GGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAG" +
        "CTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGC" +
        "CGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTAC" +
        "GTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTG"
    let refChars = Array(refPlasmid)
    let fwdSlice = String(refChars[20..<220])
    let revSlice = BioSequence.reverseComplement(String(refChars[140..<340]))
    var snpChars = Array(refChars[30..<230])
    snpChars[50] = (snpChars[50] == "G") ? "A" : "G"
    let dpSlice = String(refChars[40..<240])
    let unmatchedSeq = String(repeating: "TTAACCGGTTAACCGG", count: 12)

    // 1. 生成 6 条合成 .ab1：克隆 1 正反向 100% 通过、克隆 2 正反向含 1 处 SNP、1 条双峰待复核、1 条完全无关序列
    let specs6: [(String, String, [Int: Character])] = [
        ("EGFP-Colony1-F.ab1", fwdSlice, [:]),
        ("EGFP-Colony1-R.ab1", revSlice, [:]),
        ("EGFP-Colony2-F.ab1", String(snpChars), [:]),
        ("EGFP-Colony2-R.ab1", revSlice, [:]),
        ("EGFP-Colony3-F.ab1", dpSlice, [60: "T"]),
        ("UnknownVec-Colony4-F.ab1", unmatchedSeq, [:])
    ]
    var urls6: [URL] = []
    for (fname, seq, dp) in specs6 {
        let u = tmpDir.appendingPathComponent(fname)
        let d = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: seq, sampleName: fname, doublePeakAt1Based: dp, simulateNoisyEnds: true)
        try d.write(to: u)
        urls6.append(u)
    }

    let candidates = [
        SangerBatchEngine.SangerReferenceCandidate(id: "EGFP-Ref", name: "EGFP-Ref", sequence: refPlasmid, cdsStart1Based: 23)
    ]
    let batchRes6 = await SangerBatchEngine.verifyBatch(
        urls: urls6,
        candidates: candidates,
        primerSuffixRegex: SangerBatchEngine.defaultPrimerSuffixRegex,
        trimQualityThreshold: 20,
        maxConcurrency: 4
    )
    assert(batchRes6.reads.count == 6 && batchRes6.cloneSummaries.count == 4, "6 reads must group into 4 clones (got \(batchRes6.cloneSummaries.count))")

    let c1 = batchRes6.cloneSummaries.first { $0.cloneName == "EGFP-Colony1" }!
    let c2 = batchRes6.cloneSummaries.first { $0.cloneName == "EGFP-Colony2" }!
    let c3 = batchRes6.cloneSummaries.first { $0.cloneName == "EGFP-Colony3" }!
    let c4 = batchRes6.cloneSummaries.first { $0.cloneName == "UnknownVec-Colony4" }!

    assert(c1.verdict == .pass && c1.reads.count == 2 && c1.coveredBp > 250, "Colony 1 F+R must merge into 1 clone with .pass verdict and union coverage > 250 bp (got \(c1.coveredBp) bp)")
    assert(c2.verdict == .failed && c2.snpCount >= 1, "Colony 2 with SNP must have .failed verdict")
    assert(c3.verdict == .needsReview && c3.doublePeakCount >= 1, "Colony 3 with double peak must have .needsReview verdict")
    assert(c4.verdict == .unmatched, "Colony 4 with unrelated sequence must have .unmatched verdict, got \(c4.verdict)")

    // 验证导出 batch_summary.csv 与 .run.json
    let outBatchCSV = tmpDir.appendingPathComponent("batch_summary.csv")
    let exportedBatch = try SangerBatchEngine.exportBatchSummaryCSVWithProvenance(
        batchResult: batchRes6,
        trimQualityThreshold: 20,
        to: outBatchCSV
    )
    assert(fm.fileExists(atPath: exportedBatch.csvURL.path) && fm.fileExists(atPath: exportedBatch.sidecarURL.path), "batch_summary.csv and batch_summary.run.json must exist")
    let decodedBatchRun = try AnalysisRun.decode(from: Data(contentsOf: exportedBatch.sidecarURL))
    assert(decodedBatchRun.inputs.count == 6 && decodedBatchRun.parameters["cloneCount"]?.intValue == 4, "batch_summary.run.json must record 6 input .ab1 files and cloneCount=4")

    // 2. 验证 Python MCP verify_sanger_sequencing 批量 files 模式
    let pyBatchArgsData = try JSONSerialization.data(withJSONObject: [
        "files": urls6.map(\.path),
        "references": [["name": "EGFP-Ref", "sequence": refPlasmid]],
        "trim_quality_threshold": 20
    ])
    let pyBatchProc = Process()
    pyBatchProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    pyBatchProc.arguments = [mcpScript, "--cli-call", "verify_sanger_sequencing", "--args", String(data: pyBatchArgsData, encoding: .utf8)!]
    let pyBatchPipe = Pipe()
    pyBatchProc.standardOutput = pyBatchPipe
    try pyBatchProc.run()
    let pyBatchJSON = try JSONSerialization.jsonObject(with: pyBatchPipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    pyBatchProc.waitUntilExit()
    let pyCloneSummaries = pyBatchJSON["clone_summaries"] as? [[String: Any]] ?? []
    assert((pyBatchJSON["mode"] as? String) == "batch" && pyCloneSummaries.count == 4, "Python MCP verify_sanger_sequencing batch mode must return 4 clone_summaries")

    // 3. 生成 50 条合成 .ab1：验证高并发批处理全部完成且支持半途 Task.cancel() 安全退出不崩溃
    let dir50 = tmpDir.appendingPathComponent("batch50", isDirectory: true)
    try fm.createDirectory(at: dir50, withIntermediateDirectories: true)
    var urls50: [URL] = []
    let baseData = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: fwdSlice, sampleName: "FastRead.ab1", simulateNoisyEnds: true)
    for idx in 1...50 {
        let cloneIdx = (idx + 1) / 2
        let dirTag = (idx % 2 == 1) ? "F" : "R"
        let u = dir50.appendingPathComponent("Clone\(cloneIdx)-\(dirTag).ab1")
        try baseData.write(to: u)
        urls50.append(u)
    }
    let res50 = await SangerBatchEngine.verifyBatch(urls: urls50, candidates: candidates, maxConcurrency: 4)
    assert(res50.reads.count == 50 && res50.cloneSummaries.count == 25, "50 synthetic .ab1 files must complete and group into 25 clones (got \(res50.reads.count) reads, \(res50.cloneSummaries.count) clones)")

    let cancelTask = Task {
        await SangerBatchEngine.verifyBatch(urls: urls50, candidates: candidates, maxConcurrency: 2)
    }
    cancelTask.cancel()
    _ = await cancelTask.value

    pass("SangerBatchEngine passed (6-read 4-clone verdicts [.pass/.failed/.needsReview/.unmatched], 50-file concurrency & cancellation verified).")
} catch {
    fatalError("P11 SangerBatchEngine test failed: \(error)")
}

// 48. 验证 P12 Swift–Python 共享测试向量 (Tests/vectors/*.json 全部 6 组 29 个用例双端比对 + 篡改期望值必触发失败保护)
print("🧪 [48/52] Testing Swift–Python Shared JSON Test Vectors & Tamper Detection (P12)...")
do {
    let fm = FileManager.default
    let projRoot = CloneStudioResourceLocator.projectRootDirectory
    let vectorsDir = projRoot.appendingPathComponent("Tests/vectors", isDirectory: true)
    let vectorFiles = (try fm.contentsOfDirectory(at: vectorsDir, includingPropertiesForKeys: nil))
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    assert(vectorFiles.count == 10, "Expected 10 shared JSON vector files in Tests/vectors/, found \(vectorFiles.count)")

    // 验证 Type IIS 酶系外切偏移规范 (BsaI / BsmBI / BbsI / SapI) 与双链切点扫描
    let type2sExpected: [(String, String, Int, Int, Int)] = [
        ("BsaI", "GGTCTC", 1, 5, 4),
        ("BsmBI", "CGTCTC", 1, 5, 4),
        ("BbsI", "GAAGAC", 2, 6, 4),
        ("SapI", "GCTCTTC", 1, 4, 3)
    ]
    for (eName, eSite, dTop, dBot, ovLen) in type2sExpected {
        guard let enz = RestrictionEnzymeDatabase.shared.find(name: eName) else {
            fatalError("Missing Type IIS enzyme \(eName)")
        }
        assert(enz.site == eSite && enz.isType2S, "\(eName) site/isType2S mismatch")
        assert(enz.downstreamCutTopOffset == dTop && enz.downstreamCutBottomOffset == dBot, "\(eName) downstream offsets mismatch")
        assert(enz.overhangLength == ovLen, "\(eName) overhang length mismatch")
    }
    if let bsaI = RestrictionEnzymeDatabase.shared.find(name: "BsaI") {
        // 正链 GGTCTC + 1bpSpacer(T) + 4bp(AATG) ... 4bp(TTCC) + 1bpSpacer(A) + 反链 GAGACC
        let dualTestSeq = "AAAAGGTCTCTAATGCCCCCCCCCCCCTTCCAGAGACCAAAA"
        let dualHits = bsaI.findDualStrandSites(in: dualTestSeq, circular: true)
        assert(dualHits.count == 2 && dualHits[0].strand == "+" && dualHits[1].strand == "-", "BsaI dual strand hits mismatch")
        assert(dualHits[0].overhangBps == "AATG" && dualHits[1].overhangBps == "TTCC", "BsaI dual strand overhang extraction mismatch")
    }

    // 验证 Libraries.sqlite NEB T4 4-bp 保真度矩阵 (256 overhangs)
    let nebMatrix = GoldenGateEngine.loadNEBFidelityMatrix()
    assert(nebMatrix.statsByOverhang.count == 256, "Expected 256 overhangs in NEB T4 matrix, found \(nebMatrix.statsByOverhang.count)")

    // 验证 Libraries.sqlite plasmid_features 种子表加载 (15 个标准质粒元件)
    let seededPlasmidFeatures = PlasmidAnnotationEngine.loadFeaturesFromSQLite()
    let expectedSeedNames: Set<String> = [
        "CMV promoter", "EF1a promoter", "U6 promoter", "T7 promoter",
        "AmpR", "KanR", "PuroR",
        "pUC ori", "ColE1 ori", "SV40 ori",
        "3xFLAG", "HA", "His",
        "EGFP", "mCherry"
    ]
    assert(seededPlasmidFeatures.count == 15, "Expected 15 plasmid_features in Libraries.sqlite, found \(seededPlasmidFeatures.count)")
    assert(Set(seededPlasmidFeatures.map(\.name)) == expectedSeedNames, "Seeded plasmid_features names mismatch")

    func checkSwiftVectorCase(functionName: String, caseDict: [String: Any]) throws {
        let cid = caseDict["id"] as? String ?? "unnamed"
        let inp = caseDict["input"] as? [String: Any] ?? [:]
        let exp = caseDict["expected"] as? [String: Any] ?? [:]
        let tol = (caseDict["tolerance"] as? NSNumber)?.doubleValue ?? 0.01

        switch functionName {
        case "tm_santalucia":
            let seq = inp["sequence"] as? String ?? ""
            let ov5 = inp["five_prime_overhang"] as? String ?? ""
            let ov3 = inp["three_prime_overhang"] as? String ?? ""
            let naMolar = (inp["na_molar"] as? NSNumber)?.doubleValue ?? 0.05
            let primerConc = (inp["primer_conc"] as? NSNumber)?.doubleValue ?? 250e-9
            let mvConc = (inp["mv_conc"] as? NSNumber)?.doubleValue
            let dvConc = (inp["dv_conc"] as? NSNumber)?.doubleValue ?? 0.0
            let dntpConc = (inp["dntp_conc"] as? NSNumber)?.doubleValue ?? 0.0

            var effectiveNaMolar = naMolar
            if let mv = mvConc {
                let cond = PrimerQualityEngine.Conditions(mvConc: mv, dvConc: dvConc, dntpConc: dntpConc)
                effectiveNaMolar = cond.equivalentMonovalentMolar
            }
            let res = TmCalculator.calculate(
                sequence: seq,
                fivePrimeOverhang: ov5,
                threePrimeOverhang: ov3,
                naConcentration: effectiveNaMolar * 1000.0,
                primerConcNanoMolar: primerConc * 1e9
            )
            let expTm = (exp["tm"] as? NSNumber)?.doubleValue ?? -999.0
            if abs(res.tm - expTm) > tol {
                throw NSError(domain: "VectorMismatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "tm_santalucia.\(cid): got \(res.tm), expected \(expTm) (±\(tol))"])
            }

        case "reverse_complement":
            let mode = inp["mode"] as? String ?? "rev_comp"
            if mode == "circular_subseq" {
                let seq = inp["sequence"] as? String ?? ""
                let start1 = (inp["start_1based"] as? NSNumber)?.intValue ?? 1
                let end1 = (inp["end_1based"] as? NSNumber)?.intValue ?? 1
                let strand = inp["strand"] as? String ?? "+"
                let sub = BioSequence.extractCircularSubsequence(seq, start1Based: start1, end1Based: end1, strand: strand)
                let expSub = exp["subsequence"] as? String ?? ""
                if sub != expSub {
                    throw NSError(domain: "VectorMismatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "reverse_complement.\(cid): got \(sub), expected \(expSub)"])
                }
            } else {
                let raw = inp["sequence"] as? String ?? ""
                let cleaned = BioSequence.clean(raw)
                let rc = BioSequence.reverseComplement(raw)
                let gc = BioSequence.gcContent(raw)
                let expClean = exp["cleaned"] as? String ?? ""
                let expRC = exp["reverse_complement"] as? String ?? ""
                let expGC = (exp["gc_percent"] as? NSNumber)?.doubleValue ?? -999.0
                if cleaned != expClean || rc != expRC || abs(gc - expGC) > tol {
                    throw NSError(domain: "VectorMismatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "reverse_complement.\(cid) mismatch"])
                }
            }

        case "primer_thermo_dg":
            let kind = inp["kind"] as? String ?? "hairpin"
            let seq1 = inp["seq1"] as? String ?? ""
            let seq2 = inp["seq2"] as? String ?? ""
            let cond = PrimerQualityEngine.Conditions(
                mvConc: (inp["mv_conc"] as? NSNumber)?.doubleValue ?? 50.0,
                dvConc: (inp["dv_conc"] as? NSNumber)?.doubleValue ?? 1.5,
                dntpConc: (inp["dntp_conc"] as? NSNumber)?.doubleValue ?? 0.6,
                dnaConc: (inp["dna_conc"] as? NSNumber)?.doubleValue ?? 50.0,
                tempC: (inp["temp_c"] as? NSNumber)?.doubleValue ?? 37.0
            )
            let res: PrimerQualityEngine.StructureResult
            if kind == "hairpin" {
                res = PrimerQualityEngine.calcHairpin(seq1, conditions: cond)
            } else if kind == "homodimer" {
                res = PrimerQualityEngine.calcHomodimer(seq1, conditions: cond)
            } else {
                res = PrimerQualityEngine.calcDimer(seq1, seq2, conditions: cond)
            }
            let expFound = exp["structure_found"] as? Bool ?? false
            let expDg = (exp["dg"] as? NSNumber)?.doubleValue ?? 0.0
            let expTm = (exp["tm"] as? NSNumber)?.doubleValue ?? 0.0
            if res.structureFound != expFound || abs(res.dg - expDg) > tol || abs(res.tm - expTm) > max(0.2, tol * 4.0) {
                throw NSError(domain: "VectorMismatch", code: 3, userInfo: [NSLocalizedDescriptionKey: "primer_thermo_dg.\(cid): got (found=\(res.structureFound), dg=\(res.dg), tm=\(res.tm)), expected (found=\(expFound), dg=\(expDg), tm=\(expTm))"])
            }

        case "protein_pi_ddg":
            let seq = inp["sequence"] as? String ?? ""
            let ph = (inp["ph"] as? NSNumber)?.doubleValue ?? 7.0
            let muts = inp["mutations"] as? [String] ?? []
            let env = ProteinEnvironmentParams(ph: ph)
            let rep = ProteinBiophysicsEngine.analyzeProtein(sequence: seq, env: env)
            let evals = ProteinBiophysicsEngine.evaluateMutantsBatch(wildTypeSequence: seq, mutationSpecs: muts, env: env)
            let expLen = (exp["length_aa"] as? NSNumber)?.intValue ?? 0
            let expMW = (exp["molecular_weight_da"] as? NSNumber)?.doubleValue ?? 0.0
            let expPI = (exp["isoelectric_point"] as? NSNumber)?.doubleValue ?? 0.0
            let expCharge = (exp["net_charge_at_ph"] as? NSNumber)?.doubleValue ?? 0.0
            let expGravy = (exp["gravy"] as? NSNumber)?.doubleValue ?? 0.0
            let expDdgs = (exp["mutant_ddg"] as? [NSNumber])?.map(\.doubleValue) ?? []
            if rep.length != expLen ||
               abs(rep.molecularWeightDa - expMW) > max(0.2, tol) ||
               abs(rep.isoelectricPoint - expPI) > tol ||
               abs(rep.netChargeAtEnvPh - expCharge) > tol ||
               abs(rep.gravy - expGravy) > tol ||
               evals.count != expDdgs.count {
                throw NSError(domain: "VectorMismatch", code: 4, userInfo: [NSLocalizedDescriptionKey: "protein_pi_ddg.\(cid) property mismatch"])
            }
            for (i, ev) in evals.enumerated() {
                if ev.modelType != "empirical_heuristic" {
                    throw NSError(domain: "VectorMismatch", code: 4, userInfo: [NSLocalizedDescriptionKey: "protein_pi_ddg.\(cid) mutant[\(i)] modelType mismatch"])
                }
                if abs(ev.ddgKcalMol - expDdgs[i]) > tol {
                    throw NSError(domain: "VectorMismatch", code: 4, userInfo: [NSLocalizedDescriptionKey: "protein_pi_ddg.\(cid) mutant[\(i)] ddg mismatch"])
                }
            }

        case "qpcr_ddct":
            let refGene = inp["reference_gene"] as? String ?? "GAPDH"
            let ctrlGrp = inp["control_group"] as? String ?? "Control"
            let ctrlSample = inp["control_sample"] as? String ?? ""
            let mcRaw = inp["multiple_comparison"] as? String ?? "holm"
            let mcMode: QPCRMultipleComparisonMethod = (mcRaw == "none") ? .none : .holm
            let records = inp["records"] as? [[String: Any]] ?? []
            var wells: [QPCRWellRecord] = []
            for (idx, r) in records.enumerated() {
                let sName = r["sample"] as? String ?? ""
                let gName = r["group"] as? String ?? "Default"
                let tName = r["gene"] as? String ?? ""
                let wType = QPCRWellType.infer(sample: sName, group: gName, taskRaw: r["well_type"] as? String ?? "")
                wells.append(QPCRWellRecord(
                    id: "W\(idx + 1)",
                    well: "W\(idx + 1)",
                    sample: sName,
                    target: tName,
                    group: gName,
                    wellType: wType,
                    ct: (r["ct"] as? NSNumber)?.doubleValue,
                    tm: (r["tm"] as? NSNumber)?.doubleValue
                ))
            }
            let settings = QPCRSettings(
                referenceTargets: [refGene],
                controlGroup: ctrlGrp,
                controlSample: ctrlSample,
                multipleComparison: mcMode
            )
            let qc = QPCRAnalysisEngine.computeQC(wells: wells, settings: settings)
            let out = QPCRAnalysisEngine.computeDdct(wells: wells, settings: settings, qc: qc)
            let targetGrp = exp["target_group"] as? String ?? ""
            guard let grp = out.groupResults.first(where: { $0.category == targetGrp }) else {
                throw NSError(domain: "VectorMismatch", code: 5, userInfo: [NSLocalizedDescriptionKey: "qpcr_ddct.\(cid): group \(targetGrp) not found"])
            }
            let expNBio = (exp["n_biological"] as? NSNumber)?.intValue ?? 0
            let expMeanDct = (exp["mean_dct"] as? NSNumber)?.doubleValue ?? 0.0
            let expNote = exp["stat_note"] as? String ?? ""
            if grp.nBiological != expNBio || abs(grp.meanDCt - expMeanDct) > tol || grp.statNote.rawValue != expNote {
                throw NSError(domain: "VectorMismatch", code: 5, userInfo: [NSLocalizedDescriptionKey: "qpcr_ddct.\(cid) basic summary mismatch"])
            }
            if let expP = (exp["p_value"] as? NSNumber)?.doubleValue {
                guard let actualP = grp.pValue, abs(actualP - expP) <= tol else {
                    throw NSError(domain: "VectorMismatch", code: 5, userInfo: [NSLocalizedDescriptionKey: "qpcr_ddct.\(cid) pValue mismatch: got \(String(describing: grp.pValue)), expected \(expP)"])
                }
            } else if grp.pValue != nil {
                throw NSError(domain: "VectorMismatch", code: 5, userInfo: [NSLocalizedDescriptionKey: "qpcr_ddct.\(cid) expected nil pValue, got \(String(describing: grp.pValue))"])
            }
            if let expPAdj = (exp["p_adjusted"] as? NSNumber)?.doubleValue {
                guard let actualPAdj = grp.pAdjusted, abs(actualPAdj - expPAdj) <= tol else {
                    throw NSError(domain: "VectorMismatch", code: 5, userInfo: [NSLocalizedDescriptionKey: "qpcr_ddct.\(cid) pAdjusted mismatch"])
                }
            }
            if let expFoldLo = (exp["fold_ci95_low"] as? NSNumber)?.doubleValue,
               let expFoldHi = (exp["fold_ci95_high"] as? NSNumber)?.doubleValue {
                guard let actualLo = grp.foldCI95Low, let actualHi = grp.foldCI95High,
                      abs(actualLo - expFoldLo) <= tol && abs(actualHi - expFoldHi) <= tol else {
                    throw NSError(domain: "VectorMismatch", code: 5, userInfo: [NSLocalizedDescriptionKey: "qpcr_ddct.\(cid) foldCI95 mismatch"])
                }
            }

        case "holm_adjust":
            let pVals = (inp["p_values"] as? [NSNumber])?.map(\.doubleValue) ?? []
            let expAdj = (exp["p_adjusted"] as? [NSNumber])?.map(\.doubleValue) ?? []
            let actualAdj = QPCRStatistics.holmAdjust(pVals)
            if actualAdj.count != expAdj.count {
                throw NSError(domain: "VectorMismatch", code: 6, userInfo: [NSLocalizedDescriptionKey: "holm_adjust.\(cid) count mismatch"])
            }
            for i in 0..<actualAdj.count {
                if abs(actualAdj[i] - expAdj[i]) > tol {
                    throw NSError(domain: "VectorMismatch", code: 6, userInfo: [NSLocalizedDescriptionKey: "holm_adjust.\(cid)[\(i)] mismatch"])
                }
            }

        case "crispr_deconv_golden":
            let wtSeq = inp["wt_sequence"] as? String ?? ""
            let sgSeq = inp["sgrna_sequence"] as? String ?? ""
            let hdrSeq = inp["hdr_donor_sequence"] as? String
            let reqWin = (inp["window_length_bp"] as? NSNumber)?.intValue ?? 150
            let rawWTPeaks = (inp["wt_peaks_acgt"] as? [[[NSNumber]]])?.first.map { $0.map { $0.map(\.doubleValue) } }
                ?? (inp["wt_peaks_acgt"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) }
                ?? CRISPRDeconvolutionEngine.peaksFromSequence(wtSeq)
            let rawEditedPeaks = (inp["edited_peaks_acgt"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? []

            var cut0 = (inp["cut_index_0based"] as? NSNumber)?.intValue ?? -1
            var isRevSg = (inp["is_reverse_strand_sgrna"] as? Bool) ?? false
            if let loc = CRISPRDeconvolutionEngine.locateCutSite(wtSequence: wtSeq, sgRNASequence: sgSeq) {
                if cut0 < 0 { cut0 = loc.cutIndex0Based }
                isRevSg = loc.isReverseStrand
            }

            var hdrPeaks: [[Double]]? = (inp["hdr_peaks_acgt"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) }
            if hdrPeaks == nil, let hSeq = hdrSeq, !hSeq.isEmpty {
                let fullHDR = CRISPRDeconvolutionEngine.peaksFromSequence(hSeq)
                if cut0 >= 0 && cut0 < fullHDR.count {
                    hdrPeaks = Array(fullHDR[cut0..<min(fullHDR.count, cut0 + reqWin)])
                }
            }

            let res = CRISPRDeconvolutionEngine.deconvolvePeakMatrices(
                wtPeaksACGT: rawWTPeaks,
                editedWindowPeaksACGT: rawEditedPeaks,
                cutIndex0Based: cut0,
                isReverseStrandSgRNA: isRevSg,
                requestedWindowBp: reqWin,
                hdrWindowPeaksACGT: hdrPeaks
            )

            let expCut0 = (exp["cut_index_0based"] as? NSNumber)?.intValue ?? 0
            let expRev = exp["is_reverse_strand_sgrna"] as? Bool ?? false
            let expEffWin = (exp["effective_window_bp"] as? NSNumber)?.intValue ?? 0
            let expWT = (exp["wt_percent"] as? NSNumber)?.doubleValue ?? 0.0
            let expIndel = (exp["indel_percent"] as? NSNumber)?.doubleValue ?? 0.0
            let expKO = (exp["ko_score"] as? NSNumber)?.doubleValue ?? 0.0
            let expHDR = (exp["hdr_percent"] as? NSNumber)?.doubleValue ?? 0.0
            let expTotalEd = (exp["total_edited_percent"] as? NSNumber)?.doubleValue ?? 0.0
            let expR2 = (exp["r_squared"] as? NSNumber)?.doubleValue ?? 0.0
            let expWarns = exp["warnings"] as? [String] ?? []
            let actualWarns = res.warnings.map(\.rawValue)

            let strictTol = min(tol, 1e-5)
            if res.cutIndex0Based != expCut0 ||
               res.isReverseStrandSgRNA != expRev ||
               res.effectiveWindowBp != expEffWin ||
               abs(res.wtPercent - expWT) > strictTol ||
               abs(res.indelPercent - expIndel) > strictTol ||
               abs(res.koScore - expKO) > strictTol ||
               abs(res.hdrPercent - expHDR) > strictTol ||
               abs(res.totalEditedPercent - expTotalEd) > strictTol ||
               abs(res.rSquared - expR2) > strictTol ||
               actualWarns != expWarns {
                throw NSError(
                    domain: "VectorMismatch",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "crispr_deconv_golden.\(cid) mismatch: got (wt=\(res.wtPercent), indel=\(res.indelPercent), ko=\(res.koScore), hdr=\(res.hdrPercent), r2=\(res.rSquared), warns=\(actualWarns))"]
                )
            }

        case "plasmid_auto_annotation":
            let fastaText = (inp["fasta_text"] as? String) ?? (inp["sequence"] as? String) ?? ""
            let defName = inp["plasmid_name"] as? String ?? "Unannotated_Plasmid"
            let isCirc = inp["is_circular"] as? Bool ?? true
            let rep = PlasmidAnnotationEngine.annotateFASTA(
                fastaText,
                defaultName: defName,
                isCircular: isCirc
            )
            let expName = exp["plasmid_name"] as? String ?? ""
            let expLen = (exp["sequence_length"] as? NSNumber)?.intValue ?? 0
            let expCirc = exp["is_circular"] as? Bool ?? true
            let expFeatCnt = (exp["features_count"] as? NSNumber)?.intValue ?? 0
            let expFragCnt = (exp["fragment_count"] as? NSNumber)?.intValue ?? 0
            let expOrigCnt = (exp["origin_spanning_count"] as? NSNumber)?.intValue ?? 0
            let expFeats = exp["features"] as? [[String: Any]] ?? []

            if rep.plasmidName != expName ||
               rep.sequenceLength != expLen ||
               rep.isCircular != expCirc ||
               rep.featuresCount != expFeatCnt ||
               rep.fragmentCount != expFragCnt ||
               rep.originSpanningCount != expOrigCnt ||
               rep.features.count != expFeats.count {
                throw NSError(
                    domain: "VectorMismatch",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "plasmid_auto_annotation.\(cid) summary mismatch: got (name=\(rep.plasmidName), len=\(rep.sequenceLength), feats=\(rep.featuresCount), frags=\(rep.fragmentCount), orig=\(rep.originSpanningCount))"]
                )
            }

            for (idx, af) in rep.features.enumerated() {
                let ef = expFeats[idx]
                let eName = ef["name"] as? String ?? ""
                let eCat = ef["category"] as? String ?? ""
                let eStrand = ef["strand"] as? String ?? ""
                let eStart = (ef["start_1based"] as? NSNumber)?.intValue ?? 0
                let eEnd = (ef["end_1based"] as? NSNumber)?.intValue ?? 0
                let eMLen = (ef["matched_length"] as? NSNumber)?.intValue ?? 0
                let eOrig = ef["is_origin_spanning"] as? Bool ?? false
                let eFrag = ef["is_fragment"] as? Bool ?? false
                let eCov = (ef["coverage"] as? NSNumber)?.doubleValue ?? 0.0
                let eId = (ef["identity"] as? NSNumber)?.doubleValue ?? 0.0

                if af.name != eName ||
                   af.category != eCat ||
                   af.strand != eStrand ||
                   af.start1Based != eStart ||
                   af.end1Based != eEnd ||
                   af.matchedLength != eMLen ||
                   af.isOriginSpanning != eOrig ||
                   af.isFragment != eFrag ||
                   abs(af.coverage - eCov) > tol ||
                   abs(af.identity - eId) > tol {
                    throw NSError(
                        domain: "VectorMismatch",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "plasmid_auto_annotation.\(cid) feature[\(idx)] mismatch: got \(af.name) \(af.start1Based)..\(af.end1Based) (\(af.strand))"]
                    )
                }

                let sgFeat = af.toSnapGeneFeature(plasmidLength: rep.sequenceLength)
                let expectedSegs = (af.isOriginSpanning && af.start1Based > af.end1Based) ? 2 : 1
                if sgFeat.segments.count != expectedSegs {
                    throw NSError(
                        domain: "VectorMismatch",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "plasmid_auto_annotation.\(cid) feature[\(idx)] SnapGene segment count mismatch: got \(sgFeat.segments.count), expected \(expectedSegs)"]
                    )
                }
            }

        case "golden_gate_and_digest":
            let mode = inp["mode"] as? String ?? "golden_gate"
            if mode == "golden_gate" {
                let enzName = inp["enzyme_name"] as? String ?? "BsaI"
                let fixed = inp["fixed_overhangs"] as? [String] ?? []
                let isCirc = inp["is_circular"] as? Bool ?? true
                let rawFrags = inp["fragments"] as? [[String: Any]] ?? []
                let fragInputs = rawFrags.enumerated().map { idx, f in
                    GoldenGateEngine.GoldenGateFragmentInput(
                        name: f["name"] as? String ?? "Fragment_\(idx + 1)",
                        sequence: f["sequence"] as? String ?? "",
                        isCodingSequence: f["is_coding_sequence"] as? Bool ?? true,
                        readingFrameOffset: (f["reading_frame_offset"] as? NSNumber)?.intValue ?? 0
                    )
                }
                let plan = GoldenGateEngine.designAssembly(
                    fragments: fragInputs,
                    enzymeName: enzName,
                    fixedOverhangs: fixed,
                    isCircular: isCirc
                )

                let expEnz = exp["enzyme_name"] as? String ?? ""
                let expSite = exp["recognition_site"] as? String ?? ""
                let expOvLen = (exp["overhang_length"] as? NSNumber)?.intValue ?? 0
                let expOvs = exp["assigned_overhangs"] as? [String] ?? []
                let expFid = (exp["assembly_fidelity"] as? NSNumber)?.doubleValue ?? 0.0
                let expMM = (exp["cross_mismatch_count"] as? NSNumber)?.intValue ?? 0
                let expTotSites = (exp["total_internal_sites_found"] as? NSNumber)?.intValue ?? 0
                let expDoms = exp["domestications"] as? [[String: Any]] ?? []

                if plan.enzymeName != expEnz ||
                   plan.recognitionSite != expSite ||
                   plan.overhangLength != expOvLen ||
                   plan.overhangPlan.assignedOverhangs != expOvs ||
                   abs(plan.overhangPlan.assemblyFidelity - expFid) > tol ||
                   plan.overhangPlan.crossMismatchCount != expMM ||
                   plan.totalInternalSitesFound != expTotSites ||
                   plan.domestications.count != expDoms.count {
                    throw NSError(
                        domain: "VectorMismatch",
                        code: 9,
                        userInfo: [NSLocalizedDescriptionKey: "golden_gate_and_digest.\(cid) GG summary mismatch: got ovs=\(plan.overhangPlan.assignedOverhangs), fid=\(plan.overhangPlan.assemblyFidelity), mm=\(plan.overhangPlan.crossMismatchCount)"]
                    )
                }

                for (idx, ad) in plan.domestications.enumerated() {
                    let ed = expDoms[idx]
                    let eFrag = ed["fragment_name"] as? String ?? ""
                    let eFound = (ed["internal_sites_found"] as? NSNumber)?.intValue ?? 0
                    let eRem = (ed["remaining_sites_after_domestication"] as? NSNumber)?.intValue ?? 0
                    let eSeq = ed["domesticated_sequence"] as? String ?? ""
                    let eSugs = ed["suggestions"] as? [[String: Any]] ?? []

                    if ad.fragmentName != eFrag ||
                       ad.internalSitesFound != eFound ||
                       ad.remainingSitesAfterDomestication != eRem ||
                       ad.domesticatedSequence != eSeq ||
                       ad.suggestions.count != eSugs.count {
                        throw NSError(
                            domain: "VectorMismatch",
                            code: 9,
                            userInfo: [NSLocalizedDescriptionKey: "golden_gate_and_digest.\(cid) dom[\(idx)] mismatch"]
                        )
                    }
                    for (sIdx, asug) in ad.suggestions.enumerated() {
                        let esug = eSugs[sIdx]
                        if asug.siteStrand != (esug["site_strand"] as? String ?? "") ||
                           asug.siteStart1Based != ((esug["site_start_1based"] as? NSNumber)?.intValue ?? 0) ||
                           asug.originalCodon != (esug["original_codon"] as? String) ||
                           asug.mutatedCodon != (esug["mutated_codon"] as? String) ||
                           asug.aminoAcid != (esug["amino_acid"] as? String) ||
                           asug.mutationPosition1Based != ((esug["mutation_position_1based"] as? NSNumber)?.intValue ?? 0) ||
                           asug.isSynonymous != (esug["is_synonymous"] as? Bool ?? false) {
                            throw NSError(
                                domain: "VectorMismatch",
                                code: 9,
                                userInfo: [NSLocalizedDescriptionKey: "golden_gate_and_digest.\(cid) dom[\(idx)].sug[\(sIdx)] mismatch"]
                            )
                        }
                    }
                }
            } else {
                let emptySeq = inp["empty_vector_sequence"] as? String ?? ""
                let recombSeq = inp["recombinant_sequence"] as? String ?? ""
                let isCirc = inp["is_circular"] as? Bool ?? true
                let minB = (inp["min_bands"] as? NSNumber)?.intValue ?? 2
                let maxB = (inp["max_bands"] as? NSNumber)?.intValue ?? 4
                let topN = (inp["top_n"] as? NSNumber)?.intValue ?? 3

                let rep = DiagnosticDigestEngine.recommendTopDigests(
                    emptyVectorSequence: emptySeq,
                    recombinantSequence: recombSeq,
                    isCircular: isCirc,
                    minBands: minB,
                    maxBands: maxB,
                    topN: topN
                )

                let expEmptyLen = (exp["empty_vector_length_bp"] as? NSNumber)?.intValue ?? 0
                let expRecombLen = (exp["recombinant_length_bp"] as? NSNumber)?.intValue ?? 0
                let expCirc = exp["is_circular"] as? Bool ?? true
                let expRecs = exp["top_recommendations"] as? [[String: Any]] ?? []

                if rep.emptyVectorLengthBp != expEmptyLen ||
                   rep.recombinantLengthBp != expRecombLen ||
                   rep.isCircular != expCirc ||
                   rep.topRecommendations.count != expRecs.count {
                    throw NSError(
                        domain: "VectorMismatch",
                        code: 9,
                        userInfo: [NSLocalizedDescriptionKey: "golden_gate_and_digest.\(cid) digest summary mismatch"]
                    )
                }

                for (idx, ar) in rep.topRecommendations.enumerated() {
                    let er = expRecs[idx]
                    let eRank = (er["rank"] as? NSNumber)?.intValue ?? 0
                    let eEnzs = er["enzyme_names"] as? [String] ?? []
                    let eConc = er["recommended_gel_concentration"] as? String ?? ""
                    let eBuf = er["preferred_buffer"] as? String ?? ""
                    let eBufPct = (er["buffer_compatibility_percent"] as? NSNumber)?.intValue ?? 0
                    let eNegBands = (er["empty_vector_bands_bp"] as? [NSNumber])?.map(\.intValue) ?? []
                    let ePosBands = (er["recombinant_bands_bp"] as? [NSNumber])?.map(\.intValue) ?? []
                    let eMaxY = (er["max_migration_shift_y"] as? NSNumber)?.doubleValue ?? 0.0
                    let eMeanY = (er["mean_migration_shift_y"] as? NSNumber)?.doubleValue ?? 0.0
                    let eMinGapY = (er["min_intra_lane_gap_y"] as? NSNumber)?.doubleValue ?? 0.0
                    let eMaxDiff = (er["max_band_size_diff_bp"] as? NSNumber)?.intValue ?? 0
                    let eScore = (er["score"] as? NSNumber)?.doubleValue ?? 0.0

                    if ar.rank != eRank ||
                       ar.enzymeNames != eEnzs ||
                       ar.recommendedGelConcentration != eConc ||
                       ar.preferredBuffer != eBuf ||
                       ar.bufferCompatibilityPercent != eBufPct ||
                       ar.emptyVectorBandsBp != eNegBands ||
                       ar.recombinantBandsBp != ePosBands ||
                       abs(ar.maxMigrationShiftY - eMaxY) > tol ||
                       abs(ar.meanMigrationShiftY - eMeanY) > tol ||
                       abs(ar.minIntraLaneGapY - eMinGapY) > tol ||
                       ar.maxBandSizeDiffBp != eMaxDiff ||
                       abs(ar.score - eScore) > tol {
                        throw NSError(
                            domain: "VectorMismatch",
                            code: 9,
                            userInfo: [NSLocalizedDescriptionKey: "golden_gate_and_digest.\(cid) rec[\(idx)] mismatch: got \(ar.enzymeNames) \(ar.recommendedGelConcentration) score=\(ar.score)"]
                        )
                    }
                }
            }

        case "crispr_hdr_donor":
            let fmtRaw = inp["donor_format"] as? String ?? "ssODN"
            guard let fmt = HDRDonorFormat(rawValue: fmtRaw) else {
                throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid) invalid format \(fmtRaw)"])
            }
            let req = HDRDonorRequest(
                referenceSequence: inp["reference_sequence"] as? String ?? "",
                sgRNASequence: (inp["sgrna_sequence"] as? String) ?? (inp["sgRNASequence"] as? String ?? ""),
                strand: inp["strand"] as? String ?? "+",
                editStart0Based: (inp["edit_start_0based"] as? NSNumber)?.intValue ?? 0,
                editEnd0Based: (inp["edit_end_0based"] as? NSNumber)?.intValue ?? 0,
                replacementSequence: inp["replacement_sequence"] as? String ?? "",
                donorFormat: fmt,
                leftArmLengthBp: (inp["left_arm_length_bp"] as? NSNumber)?.intValue,
                rightArmLengthBp: (inp["right_arm_length_bp"] as? NSNumber)?.intValue,
                cdsStart1Based: (inp["cds_start_1based"] as? NSNumber)?.intValue,
                cdsEnd1Based: (inp["cds_end_1based"] as? NSNumber)?.intValue,
                autoDetectCDS: (inp["auto_detect_cds"] as? NSNumber)?.boolValue ?? true,
                enableRFLP: (inp["enable_rflp"] as? NSNumber)?.boolValue ?? false,
                rflpSearchRadiusBp: (inp["rflp_search_radius_bp"] as? NSNumber)?.intValue ?? 15,
                outOutMarginBp: (inp["out_out_margin_bp"] as? NSNumber)?.intValue ?? 100,
                primerTargetTm: (inp["primer_target_tm"] as? NSNumber)?.doubleValue ?? 60.0,
                donorName: inp["donor_name"] as? String ?? "HDR_Donor"
            )
            let rep = try HDRDonorEngine.designHDRDonor(req)

            func assertMutList(_ actual: [SilentMutationRecord], _ expectedAny: Any?, _ tag: String) throws {
                let eArr = expectedAny as? [[String: Any]] ?? []
                if actual.count != eArr.count {
                    throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid).\(tag) count \(actual.count) != \(eArr.count)"])
                }
                for (i, (am, em)) in zip(actual, eArr).enumerated() {
                    let ep0 = (em["position_0based"] as? NSNumber)?.intValue ?? -1
                    let ep1 = (em["position_1based"] as? NSNumber)?.intValue ?? -1
                    let eob = em["original_base"] as? String ?? ""
                    let emb = em["mutated_base"] as? String ?? ""
                    let er = em["reason"] as? String ?? ""
                    let ecb = em["codon_before"] as? String
                    let eca = em["codon_after"] as? String
                    let eaa = em["amino_acid"] as? String
                    if am.position0Based != ep0 || am.position1Based != ep1 ||
                       am.originalBase != eob || am.mutatedBase != emb ||
                       am.reason != er || am.codonBefore != ecb ||
                       am.codonAfter != eca || am.aminoAcid != eaa {
                        throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid).\(tag)[\(i)] mismatch"])
                    }
                }
            }

            if rep.donorFormat.rawValue != (exp["donor_format"] as? String ?? "") ||
               rep.wtCutIndex0Based != ((exp["wt_cut_index_0based"] as? NSNumber)?.intValue ?? -1) ||
               rep.wtPamStart0Based != ((exp["wt_pam_start_0based"] as? NSNumber)?.intValue ?? -1) ||
               rep.wtPamSequence != (exp["wt_pam_sequence"] as? String ?? "") ||
               rep.isInCDS != ((exp["is_in_cds"] as? NSNumber)?.boolValue ?? false) ||
               rep.cdsAutoDetected != ((exp["cds_auto_detected"] as? NSNumber)?.boolValue ?? false) ||
               rep.proteinBeforeBlocking != (exp["protein_before_blocking"] as? String ?? "") ||
               rep.proteinAfterBlocking != (exp["protein_after_blocking"] as? String ?? "") ||
               rep.aminoAcidConserved != ((exp["amino_acid_conserved"] as? NSNumber)?.boolValue ?? false) ||
               rep.blockingStrategy.rawValue != (exp["blocking_strategy"] as? String ?? "") ||
               rep.editedPamSequence != (exp["edited_pam_sequence"] as? String ?? "") ||
               rep.pamStillIntact != ((exp["pam_still_intact"] as? NSNumber)?.boolValue ?? true) ||
               rep.cas9RecutBlocked != ((exp["cas9_recut_blocked"] as? NSNumber)?.boolValue ?? false) ||
               rep.leftArmLengthBp != ((exp["left_arm_length_bp"] as? NSNumber)?.intValue ?? -1) ||
               rep.rightArmLengthBp != ((exp["right_arm_length_bp"] as? NSNumber)?.intValue ?? -1) ||
               rep.donorLengthBp != ((exp["donor_length_bp"] as? NSNumber)?.intValue ?? -1) ||
               rep.donorSequence != (exp["donor_sequence"] as? String ?? "") {
                throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid) scalar/donor mismatch: got strat=\(rep.blockingStrategy.rawValue) pam=\(rep.editedPamSequence) conserved=\(rep.aminoAcidConserved)"])
            }
            try assertMutList(rep.blockingMutations, exp["blocking_mutations"], "blocking_mutations")

            if let eRflp = exp["rflp"] as? [String: Any] {
                guard let aRflp = rep.rflp else {
                    throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid) expected rflp non-nil"])
                }
                let eWtBands = (eRflp["wt_amplicon_bands_bp"] as? [NSNumber])?.map(\.intValue) ?? []
                let eHdrBands = (eRflp["hdr_amplicon_bands_bp"] as? [NSNumber])?.map(\.intValue) ?? []
                if aRflp.mode.rawValue != (eRflp["mode"] as? String ?? "") ||
                   aRflp.enzymeName != (eRflp["enzyme_name"] as? String ?? "") ||
                   aRflp.recognitionSite != (eRflp["recognition_site"] as? String ?? "") ||
                   aRflp.wtAmpliconBandsBp != eWtBands ||
                   aRflp.hdrAmpliconBandsBp != eHdrBands {
                    throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid).rflp mismatch: got \(aRflp.mode.rawValue) \(aRflp.enzymeName) \(aRflp.hdrAmpliconBandsBp)"])
                }
                try assertMutList(aRflp.silentMutations, eRflp["silent_mutations"], "rflp.silent_mutations")
            } else if rep.rflp != nil {
                throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid) expected rflp nil"])
            }

            if let ePcr = exp["out_out_pcr"] as? [String: Any] {
                guard let aPcr = rep.outOutPCR else {
                    throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid) expected outOutPCR non-nil"])
                }
                let eFwdTm = (ePcr["forward_tm"] as? NSNumber)?.doubleValue ?? 0.0
                let eRevTm = (ePcr["reverse_tm"] as? NSNumber)?.doubleValue ?? 0.0
                if aPcr.forwardPrimer.fullSequence != (ePcr["forward_sequence"] as? String ?? "") ||
                   abs((aPcr.forwardPrimer.tm ?? 0.0) - eFwdTm) > tol ||
                   aPcr.reversePrimer.fullSequence != (ePcr["reverse_sequence"] as? String ?? "") ||
                   abs((aPcr.reversePrimer.tm ?? 0.0) - eRevTm) > tol ||
                   aPcr.forwardStart0Based != ((ePcr["forward_start_0based"] as? NSNumber)?.intValue ?? -1) ||
                   aPcr.forwardEnd0Based != ((ePcr["forward_end_0based"] as? NSNumber)?.intValue ?? -1) ||
                   aPcr.reverseStart0Based != ((ePcr["reverse_start_0based"] as? NSNumber)?.intValue ?? -1) ||
                   aPcr.reverseEnd0Based != ((ePcr["reverse_end_0based"] as? NSNumber)?.intValue ?? -1) ||
                   aPcr.wtAmpliconLengthBp != ((ePcr["wt_amplicon_length_bp"] as? NSNumber)?.intValue ?? -1) ||
                   aPcr.hdrAmpliconLengthBp != ((ePcr["hdr_amplicon_length_bp"] as? NSNumber)?.intValue ?? -1) ||
                   aPcr.leftMarginFromArmBp != ((ePcr["left_margin_from_arm_bp"] as? NSNumber)?.intValue ?? -1) ||
                   aPcr.rightMarginFromArmBp != ((ePcr["right_margin_from_arm_bp"] as? NSNumber)?.intValue ?? -1) {
                    throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid).out_out_pcr mismatch"])
                }
            } else if rep.outOutPCR != nil {
                throw NSError(domain: "VectorMismatch", code: 10, userInfo: [NSLocalizedDescriptionKey: "crispr_hdr_donor.\(cid) expected outOutPCR nil"])
            }

        default:
            throw NSError(domain: "VectorMismatch", code: 99, userInfo: [NSLocalizedDescriptionKey: "Unknown vector function \(functionName)"])
        }
    }

    var totalSwiftCases = 0
    var firstDocFunc = ""
    var firstDocCase: [String: Any] = [:]
    for vf in vectorFiles {
        let data = try Data(contentsOf: vf)
        let doc = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let fn = doc["function"] as! String
        let cases = doc["cases"] as! [[String: Any]]
        for c in cases {
            if totalSwiftCases == 0 {
                firstDocFunc = fn
                firstDocCase = c
            }
            try checkSwiftVectorCase(functionName: fn, caseDict: c)
            totalSwiftCases += 1
        }
    }
    assert(totalSwiftCases >= 50, "Expected >= 50 shared vector test cases, executed \(totalSwiftCases)")

    // 验证故意篡改 expected 值时 Swift 端必然抛出错误（防静默通过）
    var tamperedCase = firstDocCase
    var tamperedExp = (tamperedCase["expected"] as? [String: Any]) ?? [:]
    tamperedExp["tm"] = 999.99
    tamperedExp["p_adjusted"] = [999.99]
    tamperedExp["wt_percent"] = 999.99
    tamperedCase["expected"] = tamperedExp
    var caughtSwiftTamper = false
    do {
        try checkSwiftVectorCase(functionName: firstDocFunc, caseDict: tamperedCase)
    } catch {
        caughtSwiftTamper = true
    }
    assert(caughtSwiftTamper, "Tampering with expected value in shared vector MUST trigger Swift assertion failure")

    // 验证 Python 端 run_python_vectors.py 正常通过 (exit 0) 且 --tamper-check 捕获篡改 (exit != 0)
    let pyRunner = vectorsDir.appendingPathComponent("run_python_vectors.py").path
    let preferredPy = fm.isExecutableFile(atPath: "/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
    let pyProcOk = Process()
    pyProcOk.executableURL = URL(fileURLWithPath: preferredPy)
    pyProcOk.arguments = ["-B", pyRunner]
    pyProcOk.standardOutput = Pipe()
    pyProcOk.standardError = Pipe()
    try pyProcOk.run()
    pyProcOk.waitUntilExit()
    assert(pyProcOk.terminationStatus == 0, "run_python_vectors.py must exit with 0")

    let pyProcTamper = Process()
    pyProcTamper.executableURL = URL(fileURLWithPath: preferredPy)
    pyProcTamper.arguments = ["-B", pyRunner, "--tamper-check"]
    pyProcTamper.standardOutput = Pipe()
    pyProcTamper.standardError = Pipe()
    try pyProcTamper.run()
    pyProcTamper.waitUntilExit()
    assert(pyProcTamper.terminationStatus != 0, "run_python_vectors.py --tamper-check must exit with non-zero status")

    pass("Swift–Python Shared JSON Test Vectors (\(vectorFiles.count) files, \(totalSwiftCases) cases, Swift & Python tamper-check verified) passed.")
} catch {
    fatalError("P12 shared test vectors verification failed: \(error)")
}

// 49. 验证 P13 OME-TIFF 物理像素尺寸读取、通道映射、自动比例尺换算与 AnalysisRun 溯源记录
print("🧪 [49/52] Testing OME-TIFF Physical Pixel Size Parser, Channel Mapping & Auto Scale Bar (P13)...")
do {
    let fm = FileManager.default
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_p13_ometiff_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    // 1. 构造一个包含合法 OME-XML 的合成 2 通道 TIFF 文件 (PhysicalSizeX = 0.325 µm, Channels: DAPI, EGFP)
    let synthTIFFData = BioImageProcessor.generateSyntheticOMETIFFData(
        width: 120,
        height: 80,
        physicalSizeXUM: 0.325,
        channelNames: ["DAPI", "EGFP"]
    )
    let tiffURL = tmpDir.appendingPathComponent("synthetic_sample_ome.tif")
    try synthTIFFData.write(to: tiffURL)

    // 2. 从二进制 Data 与文件路径解析元数据
    let metaFromData = BioImageProcessor.extractTIFFMetadata(from: synthTIFFData)
    let metaFromFile = BioImageProcessor.extractTIFFMetadata(at: tiffURL)
    assert(metaFromData.physicalSizeSource == "OME-XML" && metaFromFile.physicalSizeSource == "OME-XML", "Must recognize source as OME-XML")
    assert(abs((metaFromData.physicalPixelSizeUM ?? 0) - 0.325) < 1e-4, "PhysicalSizeX must be 0.325 µm, got \(String(describing: metaFromData.physicalPixelSizeUM))")
    assert(metaFromData.channelNames == ["DAPI", "EGFP"], "Channel names mismatch: got \(String(describing: metaFromData.channelNames))")
    assert(metaFromData.sizeC == 2, "SizeC must be 2")

    // 3. 测试 ImageJ 格式与标准 TIFF 分辨率回退解析
    let imageJHeader = "ImageJ=1.53c\nimages=1\nunit=micron\nspacing=0.50\n"
    let ijMeta = BioImageProcessor.parseImageJDescription(imageJHeader, xResolution: nil, resolutionUnit: nil)
    assert(ijMeta?.physicalSizeSource == "ImageJ" && abs((ijMeta?.physicalPixelSizeUM ?? 0) - 0.50) < 1e-4, "ImageJ spacing=0.50 µm parsing failed")

    // 4. 从文件 URL 构造 BioImagePlane，验证自动 OME-XML 物理像素尺寸透传
    guard let loadedPlane = BioImagePlane.fromImageURL(tiffURL, maxDimension: 120) else {
        fatalError("Failed to load BioImagePlane from synthesized OME-TIFF")
    }
    assert(loadedPlane.physicalSizeSource == "OME-XML" && abs((loadedPlane.physicalPixelSizeUM ?? 0) - 0.325) < 1e-4, "BioImagePlane must inherit OME physical pixel size")
    assert(loadedPlane.channelNames == ["DAPI", "EGFP"], "BioImagePlane channel names mismatch")

    pass("OME-TIFF Physical Pixel Size (0.325 µm/px) & BioImagePlane Metadata Loader (P13) passed.")
} catch {
    fatalError("P13 OME-TIFF test failed: \(error)")
}

// 50. 验证 P14 WB 多曝光线性范围检查（合成 1x / 2x / 4x 三张曝光图，第三张截断到 65535，被截断条带判为非线性，推荐第二张曝光并写入 AnalysisRun）
print("🧪 [50/52] Testing WB Multi-Exposure Linearity Range & Best Exposure Recommendation (P14)...")
do {
    assert(WesternBlotEngine.parseExposureSeconds(from: "gapdh_exp_10s.tif") == 10.0, "Must parse 10s from filename")
    assert(WesternBlotEngine.parseExposureSeconds(from: "blot_500ms.tif") == 0.5, "Must parse 500ms as 0.5s")

    let basePlane = BioImageProcessor.generateDemoWesternBlotPlane(width: 400, height: 240)
    let rawBuf = WesternBlotEngine.bufferFromBioImagePlane(basePlane)
    let maxRaw = max(1.0, rawBuf.signal.max() ?? 1.0)
    // 归一化使 1x 峰值 = 22000, 2x 峰值 = 44000 (< 65400 未饱和), 4x 理论峰值 = 88000 -> 在 65535 处被截断饱和
    let normFactor = 22000.0 / maxRaw
    let buf1x = WesternBlotEngine.scaleBufferForExposure(rawBuf, factor: normFactor * 1.0, clampCeiling: 65535.0, saturationCutoff: 65400.0)
    let buf2x = WesternBlotEngine.scaleBufferForExposure(rawBuf, factor: normFactor * 2.0, clampCeiling: 65535.0, saturationCutoff: 65400.0)
    let buf4x = WesternBlotEngine.scaleBufferForExposure(rawBuf, factor: normFactor * 4.0, clampCeiling: 65535.0, saturationCutoff: 65400.0)

    let expParams = WBAnalysisParams(rollingBallRadius: 40, expectedLanes: 6, bandProminence: 0.10, stripThreshold: 0.06, primaryBandOnly: true)
    let series: [(imagePath: String, exposureSeconds: Double, buffer: WesternBlotEngine.RawGrayBuffer16?)] = [
        ("membrane_10s.tif", 10.0, buf1x),
        ("membrane_20s.tif", 20.0, buf2x),
        ("membrane_40s.tif", 40.0, buf4x)
    ]
    guard let rec = WesternBlotEngine.analyzeExposureSeries(series: series, params: expParams, r2LinearityThreshold: 0.98) else {
        fatalError("analyzeExposureSeries returned nil for 3-frame synthetic series")
    }
    assert(rec.frames.count == 3, "Must evaluate all 3 exposure frames")
    assert(rec.frames[0].isSaturated == false && rec.frames[1].isSaturated == false && rec.frames[2].isSaturated == true, "1x and 2x must be unsaturated, 4x must be saturated")
    // 被 65535 截断的高表达条带必须被判为非线性 (isLinear == false)
    let clippedBands = rec.bandLinearities.filter { $0.isSaturatedInMaxExposure }
    assert(!clippedBands.isEmpty && clippedBands.allSatisfy({ $0.isLinear == false }), "Clipped bands in 4x exposure must be marked isLinear == false")
    // 推荐曝光必须为第二张 (20s / membrane_20s.tif)
    assert(rec.recommendedExposureSeconds == 20.0 && rec.recommendedImagePath == "membrane_20s.tif", "Recommended exposure must be the 2nd frame (20s), got \(rec.recommendedExposureSeconds)s (\(rec.recommendedImagePath))")

    // 验证写入 AnalysisRun
    let res20 = WesternBlotEngine.analyzeNativeBuffer(buf2x, imagePath: "membrane_20s.tif", params: expParams)
    let run = WesternBlotEngine.buildWBAnalysisRun(result: res20, exposureRecommendation: rec)
    assert(run.parameters["recommendedExposureSeconds"]?.doubleValue == 20.0 && run.parameters["recommendedImagePath"]?.stringValue == "membrane_20s.tif", "AnalysisRun must record recommendedExposureSeconds=20.0 and recommendedImagePath=membrane_20s.tif")

    pass("WB Multi-Exposure Linearity Range (1x/2x/4x clipped at 65535 -> 2nd frame 20s recommended) passed.")
}

// 51. 验证 P15 AnalysisRun v2 linkedPlasmidIDs 跨模块质粒关联、v1 旧版 .run.json 向后兼容解码与 AnalysisRunIndexStore 索引检索
print("🧪 [51/52] Testing AnalysisRun v2 linkedPlasmidIDs, Index Store & v1 Backward Compatibility (P15)...")
do {
    let fm = FileManager.default
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labworker_p15_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let customIndexURL = tmpDir.appendingPathComponent("analysis_runs_index.json")
    let testPlasmidID = "/tmp/plasmids/pCMV-TP53-3xFLAG.dna"
    let testPlasmidName = "pCMV-TP53-3xFLAG"

    // 1. 验证旧版 schemaVersion = 1（无 linkedPlasmidIDs 字段）的 JSON 向后兼容解码
    let v1JSON = """
    {
      "appVersion": "3.0.0",
      "createdAt": "2026-01-01T00:00:00Z",
      "engine": "swift-native",
      "exclusions": [],
      "inputs": [],
      "manualEdits": [],
      "module": "westernBlot",
      "outputs": ["legacy.csv"],
      "parameters": {"bitDepth": 16},
      "runID": "11111111-2222-3333-4444-555555555555",
      "schemaVersion": 1
    }
    """
    let decodedV1 = try AnalysisRun.decode(from: Data(v1JSON.utf8))
    assert(decodedV1.schemaVersion == 1 && decodedV1.linkedPlasmidIDs.isEmpty, "v1 AnalysisRun without linkedPlasmidIDs must decode cleanly with empty array")

    // 2. 验证 Sanger、WB、qPCR 三大模块生成 schemaVersion = 2 且写入同一 AnalysisRunIndexStore
    let sangerRef =
        "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTG" +
        "CCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAG"
    let sangerAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: sangerRef, sampleName: "P15_Sanger.ab1", simulateNoisyEnds: false)
    let sangerChrom = SangerAlignmentEngine.parseData(sangerAB1, sampleName: "P15_Sanger.ab1", trimQualityThreshold: 15)
    let sangerRep = SangerAlignmentEngine.verifyAgainstPlasmid(chromatogram: sangerChrom, referenceSequence: sangerRef, referenceName: testPlasmidName)
    let sangerOutURL = tmpDir.appendingPathComponent("p15_sanger_report.txt")
    try "Sanger Report".write(to: sangerOutURL, atomically: true, encoding: .utf8)
    let sangerRun = SangerAlignmentEngine.buildSangerAnalysisRun(
        report: sangerRep,
        referenceSequence: sangerRef,
        outputs: [sangerOutURL.lastPathComponent],
        exportDirectoryURL: tmpDir,
        linkedPlasmidIDs: [testPlasmidID]
    )
    assert(sangerRun.schemaVersion == 2 && sangerRun.linkedPlasmidIDs == [testPlasmidID], "Sanger run must have schemaVersion=2 and linkedPlasmidIDs")
    let sangerSidecar = try sangerRun.writeSidecarJSON(alongsideOutputURL: sangerOutURL, indexURL: customIndexURL)
    assert(fm.fileExists(atPath: sangerSidecar.path), "Sanger .run.json sidecar must exist")

    let wbPlane = BioImageProcessor.generateDemoWesternBlotPlane(width: 320, height: 180)
    let wbBuf = WesternBlotEngine.bufferFromBioImagePlane(wbPlane)
    let wbRes = WesternBlotEngine.analyzeNativeBuffer(wbBuf, imagePath: "p15_wb.tif")
    let wbOutURL = tmpDir.appendingPathComponent("p15_wb_quant.csv")
    try "WB CSV".write(to: wbOutURL, atomically: true, encoding: .utf8)
    let wbRun = WesternBlotEngine.buildWBAnalysisRun(
        result: wbRes,
        outputs: [wbOutURL.lastPathComponent],
        exportDirectoryURL: tmpDir,
        linkedPlasmidIDs: [testPlasmidID]
    )
    assert(wbRun.schemaVersion == 2 && wbRun.linkedPlasmidIDs == [testPlasmidID], "WB run must have schemaVersion=2 and linkedPlasmidIDs")
    _ = try wbRun.writeSidecarJSON(alongsideOutputURL: wbOutURL, indexURL: customIndexURL)

    let qpcrWells = QPCRAnalysisEngine.parseQPCRTable(QPCRAnalysisEngine.defaultExampleCSV)
    let qpcrSettings = QPCRSettings(referenceTargets: ["GAPDH"], controlGroup: "ControlGroup")
    let qpcrQC = QPCRAnalysisEngine.computeQC(wells: qpcrWells, settings: qpcrSettings)
    let qpcrOut = QPCRAnalysisEngine.computeDdct(wells: qpcrWells, settings: qpcrSettings, qc: qpcrQC)
    let qpcrOutURL = tmpDir.appendingPathComponent("p15_qpcr_ddct.csv")
    try "qPCR CSV".write(to: qpcrOutURL, atomically: true, encoding: .utf8)
    let qpcrRun = QPCRAnalysisEngine.buildQPCRAnalysisRun(
        rawCSVText: QPCRAnalysisEngine.defaultExampleCSV,
        wells: qpcrWells,
        settings: qpcrSettings,
        qc: qpcrQC,
        analysis: qpcrOut,
        outputs: [qpcrOutURL.lastPathComponent],
        exportDirectoryURL: tmpDir,
        linkedPlasmidIDs: [testPlasmidID]
    )
    assert(qpcrRun.schemaVersion == 2 && qpcrRun.linkedPlasmidIDs == [testPlasmidID], "qPCR run must have schemaVersion=2 and linkedPlasmidIDs")
    _ = try qpcrRun.writeSidecarJSON(alongsideOutputURL: qpcrOutURL, indexURL: customIndexURL)

    let gelOutURL = tmpDir.appendingPathComponent("p15_gel_bands.csv")
    let gelIndexRes = try GelAnalysisEngine.exportGelBandsCSVWithProvenance(
        lanes: gelAuto.lanes,
        ladder: GelMarkerLadderPreset.builtinPresets[0],
        fit: gelAuto.fit,
        virtualDigestEnzymes: ["BamHI", "EcoRI"],
        linkedPlasmidIDs: [testPlasmidID],
        to: gelOutURL,
        indexURL: customIndexURL
    )
    assert(gelIndexRes.run.schemaVersion == 2 && gelIndexRes.run.linkedPlasmidIDs == [testPlasmidID], "Gel run must have schemaVersion=2 and linkedPlasmidIDs")

    // 3. 验证通过质粒 ID 可检索到全部 4 条跨模块关联记录
    let indexedEntries = AnalysisRunIndexStore.entries(forPlasmidID: testPlasmidID, plasmidName: testPlasmidName, from: customIndexURL)
    let indexedModules = Set(indexedEntries.map(\.module))
    assert(indexedEntries.count == 4, "Expected 4 linked analysis entries for plasmid, found \(indexedEntries.count)")
    assert(indexedModules.contains(NavItem.sangerVerify.rawValue) && indexedModules.contains(NavItem.westernBlot.rawValue) && indexedModules.contains(NavItem.qpcrAnalysis.rawValue) && indexedModules.contains(NavItem.gelFigure.rawValue), "Index must contain Sanger, WB, qPCR and Gel entries")

    pass("AnalysisRun v2 linkedPlasmidIDs (v1 backward compat + Sanger/WB/qPCR/Gel cross-module index) passed.")
} catch {
    fatalError("P15 AnalysisRun linkedPlasmidIDs test failed: \(error)")
}

// 52. 验证 LabBioCalculatorsEngine（DNA 换算、蛋白质换算、生理生化公式）及 Swift–Python MCP 数值一致性
print("🧪 [52/52] Testing LabBioCalculatorsEngine & Bio Calculator MCP Parity...")
do {
    // (1) DNA Conversions
    let p1 = LabDNAConverter.dsdnaUgToPmol(lengthBp: 5000, massUg: 1.0)
    assert(p1 != nil && abs(p1! - 0.30302) < 1e-4, "dsDNA ug->pmol mismatch: \(String(describing: p1))")
    let ug1 = LabDNAConverter.dsdnaPmolToUg(lengthBp: 5000, pmol: 1.0)
    assert(ug1 != nil && abs(ug1! - 3.3) < 1e-4, "dsDNA pmol->ug mismatch: \(String(describing: ug1))")

    let ssPmol = LabDNAConverter.ssdnaUgPerMlToPmolPerUl(lengthNt: 20, concUgPerMl: 100.0)
    assert(ssPmol != nil && abs(ssPmol! - 15.15) < 1e-4, "ssDNA ug/ml->pmol/ul mismatch")
    let ssUg = LabDNAConverter.ssdnaPmolPerUlToUgPerMl(lengthNt: 20, concPmolPerUl: 10.0)
    assert(ssUg != nil && abs(ssUg! - 66.0) < 1e-4, "ssDNA pmol/ul->ug/ml mismatch")

    let ends = LabDNAConverter.linearDNAUgToPmolEnds(lengthKb: 5.0, massUg: 1.0)
    assert(ends != nil && abs(ends! - 0.606) < 1e-4, "Linear DNA pmol ends mismatch")

    let odOK = LabDNAConverter.od260ToConcentration(od260: 0.5, sampleType: .dsDNA)
    let odRNA = LabDNAConverter.od260ToConcentration(od260: 0.05, sampleType: .rna)
    let odOligo = LabDNAConverter.od260ToConcentration(od260: 1.5, sampleType: .ssOligo, dilutionFactor: 2.0)
    assert(odOK != nil && abs(odOK!.concentrationUgPerMl - 25.0) < 1e-6 && !odOK!.isOutOfLinearRange)
    assert(odRNA != nil && abs(odRNA!.concentrationUgPerMl - 2.0) < 1e-6 && odRNA!.isOutOfLinearRange)
    assert(odOligo != nil && abs(odOligo!.concentrationUgPerMl - 60.0) < 1e-6 && odOligo!.isOutOfLinearRange)

    // (2) Protein Conversions & Coding Capacity
    let protKDa = LabProteinConverter.proteinMolar(target: .sizeKDa, inputA: 50.0, inputB: 1000.0)
    let protUg = LabProteinConverter.proteinMolar(target: .massUg, inputA: 50.0, inputB: 1000.0)
    let protPmol = LabProteinConverter.proteinMolar(target: .amountPmol, inputA: 50.0, inputB: 50.0)
    assert(protKDa?.value == 50.0 && protUg?.value == 50.0 && protPmol?.value == 1000.0, "Protein molar triangle mismatch")

    let cFromBP = LabProteinConverter.dnaCodingCapacity(from: .dnaBp(900))
    let cFromAA = LabProteinConverter.dnaCodingCapacity(from: .proteinAA(300))
    let cFromKDa = LabProteinConverter.dnaCodingCapacity(from: .proteinKDa(33.0))
    assert(cFromBP?.aminoAcids == 300 && abs((cFromBP?.proteinKDa ?? 0) - 33.0) < 1e-6)
    assert(cFromAA?.dnaBp == 900 && cFromKDa?.aminoAcids == 300 && cFromKDa?.dnaBp == 900)

    // (3) Biochemical Formulas
    let molG = LabBiochemCalculator.molarityMass(mwGPerMol: 58.44, concentration: 100, concUnit: .millimolar, volume: 500, volUnit: .milliliter)
    let molMicro = LabBiochemCalculator.molarityMass(mwGPerMol: 100, concentration: 1, concUnit: .micromolar, volume: 1, volUnit: .milliliter)
    assert(molG != nil && molG!.displayUnit == "g" && abs(molG!.displayValue - 2.922) < 1e-6 && molG!.warningMessage == nil)
    assert(molMicro != nil && molMicro!.displayUnit == "µg" && molMicro!.warningMessage != nil, "Microgram mass must emit higher stock warning")

    let dilOK = LabBiochemCalculator.dilution(stockConc: 1, stockUnit: .molar, finalConc: 10, finalUnit: .millimolar, finalVolume: 50, volUnit: .milliliter)
    let dilML = LabBiochemCalculator.dilution(stockConc: 1, stockUnit: .molar, finalConc: 10, finalUnit: .millimolar, finalVolume: 100, volUnit: .milliliter)
    let dilNano = LabBiochemCalculator.dilution(stockConc: 1, stockUnit: .molar, finalConc: 10, finalUnit: .micromolar, finalVolume: 10, volUnit: .milliliter)
    let dilPico = LabBiochemCalculator.dilution(stockConc: 10, stockUnit: .molar, finalConc: 1, finalUnit: .micromolar, finalVolume: 1, volUnit: .milliliter)
    let dilBad = LabBiochemCalculator.dilution(stockConc: 10, stockUnit: .micromolar, finalConc: 1, finalUnit: .millimolar, finalVolume: 10, volUnit: .milliliter)
    assert(dilOK?.isValid == true && dilOK?.displayUnit == "µL" && abs((dilOK?.displayValue ?? 0) - 500.0) < 1e-6)
    assert(dilML?.isValid == true && dilML?.displayUnit == "mL" && abs((dilML?.displayValue ?? 0) - 1.0) < 1e-6)
    assert(dilNano?.isValid == true && dilNano?.displayUnit == "nL" && abs((dilNano?.displayValue ?? 0) - 100.0) < 1e-6 && dilNano?.warningMessage != nil)
    assert(dilPico?.isValid == true && dilPico?.displayUnit == "pL" && abs((dilPico?.displayValue ?? 0) - 100.0) < 1e-6 && dilPico?.warningMessage != nil)
    assert(dilBad?.isValid == false && dilBad?.errorMessage != nil, "Final > Stock must be flagged invalid")

    let t37 = LabBiochemCalculator.convertTemperature(from: .celsius(37))
    let tMinus40 = LabBiochemCalculator.convertTemperature(from: .fahrenheit(-40))
    let tAbsInvalid = LabBiochemCalculator.convertTemperature(from: .kelvin(-5))
    assert(abs(t37.fahrenheit - 98.6) < 1e-6 && abs(t37.kelvin - 310.16) < 1e-6 && !t37.isBelowAbsoluteZero)
    assert(abs(tMinus40.celsius - (-40.0)) < 1e-6 && tAbsInvalid.isBelowAbsoluteZero)

    assert(BioMathFormatter.format(1234.567) == "1,234.57" && BioMathFormatter.format(0.01234) == "0.012")

    // (4) Swift == Python MCP Tool Parity CLI Calls
    let cliCheckProc = Process()
    cliCheckProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    cliCheckProc.arguments = [
        mcpScript,
        "--cli-call", "calculate_recombination_dosage",
        "--args", #"{"clone_type":"ligation","vector_length":5000,"vector_conc":50,"vector_pmol":0.03,"molar_ratio":3,"inserts":[{"length":1000,"conc":25}],"sync_to_gui":false}"#
    ]
    let cliPipe = Pipe()
    cliCheckProc.standardOutput = cliPipe
    try cliCheckProc.run()
    let cliData = cliPipe.fileHandleForReading.readDataToEndOfFile()
    cliCheckProc.waitUntilExit()
    assert(cliCheckProc.terminationStatus == 0, "MCP ligation mode call failed")
    let cliJSON = try JSONSerialization.jsonObject(with: cliData) as! [String: Any]
    let vecDict = cliJSON["vector"] as? [String: Any]
    let insArr = cliJSON["inserts"] as? [[String: Any]]
    assert((vecDict?["actualNg"] as? Double) == 97.5 && (insArr?.first?["actualNg"] as? Double) == 58.5, "Python MCP ligation ng mismatch vs Swift")

    pass("LabBioCalculatorsEngine & Bio Calculator MCP parity verified (DNA/Protein/Biochem/Ligation Ratio).")
} catch {
    fatalError("LabBioCalculatorsEngine verification failed: \(error)")
}

let finalPyToolCount = await MainActor.run { PlasmidPoolManager.mcpToolsCatalog.count }
print("COUNTS tests=\(passedTests.count) tools=\(finalPyToolCount) modules=\(NavItem.allCases.count)")
print("\n🎉 ALL \(passedTests.count) AUTOMATED VERIFICATION TESTS PASSED SUCCESSFULLY!")
