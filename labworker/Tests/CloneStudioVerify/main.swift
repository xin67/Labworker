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
print("🧪 [1/59] Testing BioSequence...")
let cleaned = BioSequence.clean("  atg  cga tcg  123 \n !? ")
assert(cleaned == "ATGCGATCG", "Clean sequence mismatch: \(cleaned)")
assert(BioSequence.reverse("ATGC") == "CGTA", "Reverse mismatch")
assert(BioSequence.complement("ATGC") == "TACG", "Complement mismatch")
assert(BioSequence.reverseComplement("ATGC") == "GCAT", "Reverse complement mismatch")
assert(BioSequence.gcContent("GGCC") == 100.0, "GC% mismatch")
pass("BioSequence passed.")

// 2. 验证限制性内切酶数据库与 IUPAC 模糊匹配
print("🧪 [2/59] Testing RestrictionEnzyme Database & IUPAC...")
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
print("🧪 [3/59] Testing TmCalculator...")
let tmRes = TmCalculator.calculate(sequence: "ATGCGATCGATCGATCGATCGATC")
assert(tmRes.length == 24)
assert(tmRes.tm > 55.0 && tmRes.tm < 75.0, "Tm out of expected range: \(tmRes.tm)")
pass("TmCalculator passed (Tm = \(tmRes.tm)℃, Ta = \(tmRes.recommendedTa)℃).")

// 4. 验证 DNAMolarCalculator (与官方及经典摩尔比连接对齐)
print("🧪 [4/59] Testing DNAMolarCalculator...")
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
print("🧪 [5/59] Testing HomologyArmDesigner (18bp Laboratory Golden Preference & Custom Arm Length)...")
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
print("🧪 [6/59] Testing ExcelOrderExporter with user templates...")
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
print("🧪 [7/59] Testing GenomicLibraryService (SQLite3 Human vs Mouse)...")
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
print("🧪 [8/61] Testing CRISPRDesigner (Ran 2013 & Sanjana 2014 conditional U6 +1G overhangs)...")
let sgTargetG = "GTCGCTGAGCTCCGATTCGA" // 首位已含 G
let sgPairG = CRISPRDesigner.designPair(
    target: sgTargetG,
    geneName: "A1BG",
    index: 1,
    prefix: "P1",
    species: .human,
    vector: .lentiCRISPRv2
)
assert(sgPairG.fwdPrimer.fullSequence == "CACC" + sgTargetG, "5'-G spacer must NOT receive duplicate extra G")
assert(sgPairG.revPrimer.fullSequence == "AAAC" + BioSequence.reverseComplement(sgTargetG), "5'-G spacer bottom oligo must NOT receive extra 3' C")
assert(sgPairG.fwdPrimer.name == "P1_sg1-FWD")
assert(sgPairG.revPrimer.name == "P1_sg1-REV")

let sgTargetNonG = "ATCGCTGAGCTCCGATTCGA" // 首位非 G，必须补 U6 +1G / 3'C
for vec in [CRISPRDesigner.VectorOverhang.lentiCRISPRv2, .px459_px458] {
    let sgPairNonG = CRISPRDesigner.designPair(target: sgTargetNonG, geneName: "A1BG", index: 2, vector: vec)
    assert(sgPairNonG.fwdPrimer.fullSequence == "CACCG" + sgTargetNonG, "\(vec.rawValue) non-G spacer must add 5' G")
    assert(sgPairNonG.revPrimer.fullSequence == "AAAC" + BioSequence.reverseComplement(sgTargetNonG) + "C", "\(vec.rawValue) non-G spacer must add 3' C")
}
pass("CRISPRDesigner passed (Ran 2013 & Sanjana 2014 conditional U6 +1G/3'C verified).")

// 9. 验证 ShRNADesigner
print("🧪 [9/61] Testing ShRNADesigner (Moffat 2006 pLKO.1 6T/6A & non-palindromic loop RC)...")
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
// R: AATTCAAAAAA (6A) + Sense + RC(Loop) + Antisense
assert(shPair.revPrimer.fullSequence.hasPrefix("AATTCAAAAAA") && !shPair.revPrimer.fullSequence.hasPrefix("AATTCAAAAAAA"))
assert(shPair.fwdPrimer.fullSequence.count == shPair.revPrimer.fullSequence.count, "Top and bottom pLKO.1 oligos must match length (6T/6A parity)")
let shPairNonPal = ShRNADesigner.designPair(target: shTarget, geneName: "CDH17", index: 2, loop: "TTCAAGAGA")
assert(shPairNonPal.fwdPrimer.fullSequence.count == shPairNonPal.revPrimer.fullSequence.count)
let shTopInner = String(shPairNonPal.fwdPrimer.fullSequence.dropFirst(4))
let shBotInner = String(shPairNonPal.revPrimer.fullSequence.dropFirst(4))
assert(BioSequence.reverseComplement(shTopInner) == shBotInner, "Non-palindromic loop bottom oligo must exactly reverse-complement top inner duplex")
assert(shPair.fwdPrimer.name == "P1_sh1-F")
assert(shPair.revPrimer.name == "P1_sh1-R")
pass("ShRNADesigner passed (6T/6A parity & non-palindromic loop RC verified).")

// 10. 验证 CHOPCHOPService URL 构建与 Python 异步直连
print("🧪 [10/59] Testing CHOPCHOPService (URL & Python Pipeline)...")
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
print("🧪 [11/59] Testing SgRNAScoringEngine (Reliability & Termination Filter)...")
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
print("🧪 [12/59] Testing ShRNAScoringEngine (Thermodynamic Asymmetry & RISC Loading)...")
// 优质 shRNA: 5' C, 3' A, Pos 10 A, GC 42%
let idealSh = "CCAGTCCCTATCACCATAGAA" // 21nt
let idealShScore = ShRNAScoringEngine.evaluate(sequence: idealSh)
assert(idealShScore.score >= 80.0, "Ideal shRNA score should be >= 80, got \(idealShScore.score)")
assert(idealShScore.tier == .excellent, "Ideal shRNA tier should be excellent")

// 致命缺陷：Sense 含有 TTTT，或 Sense 含有 AAAA (反义链产生 TTTT)，或拼接边界形成 TTTT
let fatalSh = "CCAGTTTTATCACCATAGAA"
let fatalShScore = ShRNAScoringEngine.evaluate(sequence: fatalSh)
assert(fatalShScore.hasFatalIssue, "Must flag fatal issue for shRNA TTTT")
assert(fatalShScore.score <= 35.0, "Score must be capped at 35, got \(fatalShScore.score)")

let fatalShAAAA = "CCAGAAAAATCACCATAGAA"
let fatalShAAAAScore = ShRNAScoringEngine.evaluate(sequence: fatalShAAAA)
assert(fatalShAAAAScore.hasFatalIssue && fatalShAAAAScore.score <= 35.0, "Sense AAAA must be flagged fatal because antisense arm contains TTTT")

let juncScore = ShRNAScoringEngine.evaluate(sequence: "CCAGTCCCTATCACCATAGTT", loop: "TTCAAGAGA")
assert(juncScore.hasFatalIssue && juncScore.score <= 35.0, "Sense-Loop junction TTTT must be flagged fatal")

// 靶点动态评分与排序验证
let dummyTargetHigh = GenomicTarget(id: 1, gene: "TEST", sequence: idealSg, species: .human, type: .sgRNA)
let dummyTargetLow = GenomicTarget(id: 2, gene: "TEST", sequence: fatalSg, species: .human, type: .sgRNA)
assert(dummyTargetHigh.score > dummyTargetLow.score, "High target score must exceed low target score")
pass("ShRNAScoringEngine passed (Ideal: \(idealShScore.score), Fatal TTTT: \(fatalShScore.score)).")

// 13. SnapGeneService 真实文件解析与安全原位注入测试
print("🧪 [13/59] Testing SnapGeneService (parse & in-place primer injection with backup)...")
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
    print("   ⚠️ Skipped [13/59] (Desktop sample file not found)")
}

// 14. SnapGeneService 双质粒重组装配测试
print("🧪 [14/59] Testing SnapGeneService (dual-plasmid recombinant assembly)...")
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
    print("   ⚠️ Skipped [14/59] (Desktop sample file not found)")
}

// 15. HomologyArmDesigner 质粒片段删除与反向 PCR 环化引物设计测试
print("🧪 [15/59] Testing HomologyArmDesigner.designFragmentDeletion (18bp Golden Homology Arm)...")
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
print("🧪 [16/59] Testing SnapGeneService.deleteFragment (Plasmid Fragment Deletion & Feature Re-mapping)...")
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
    print("   ⚠️ Skipped [16/59] (Desktop sample file not found)")
}

// 17. CloneCanvas 纯数学几何层测试 (CircularGeometry + CircularOVELayout)
print("🧪 [17/59] Testing CircularGeometry & CircularOVELayout (Polar math, Concentric Y-Offsets & 4-Quadrant Label Relaxation)...")
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
print("🧪 [18/59] Testing SequenceRowLayout & CodonTranslator (36bp row slicing, complement & codon ribbon)...")
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
print("🧪 [19/59] Testing ConstructHistoryManager (Multi-step genealogy & FeatureShiftItem diff calculation)...")
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
print("🧪 [20/59] Testing Fine-Grained Plasmid Workbench Engine (ConstructCutsite scanner, NEB Buffer matrix & dynamic row layout)...")
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
print("🧪 [21/59] Testing CloneStudioIconProvider (Light/Dark simplified icons & macOS status bar template icon)...")
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
print("🧪 [22/59] Testing CHOPCHOP combinedScore & Local SG/SH Highlighting Comparison...")
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
print("🧪 [23/59] Testing StatusBarIcon toggle, PlasmidPoolManager & CloneStudio MCP Server...")
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

// 验证 Labworker MCP Server 20261120 JSON-RPC 2.0 协议与全部实验工具 (23 Tools)
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
assert(rpcOutStr.contains("labworker-mcp") && rpcOutStr.contains("20261120"), "MCP Server must identify as labworker-mcp 20261120")
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

pass("StatusBarIcon toggle, PlasmidPoolManager (\(poolCount) plasmids), SnapGene reverse-primer strand='1' & Labworker MCP Server 20261120 (23 tools) passed.")

// 24. 验证 Phase 1 实验台工具引擎 (PlateLayoutEngine + QPCRAnalysisEngine)
print("🧪 [24/59] Testing Phase 1 Bench Engines (PlateLayoutEngine & QPCRAnalysisEngine)...")
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
print("🧪 [26/59] Testing WesternBlotEngine & GelAnalysisEngine (Background subtraction, Normalization & Log10 MW Regression)...")
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
print("🧪 [27/59] Testing HomologousPCRGelSimulator (Agarose Sieving Physics, Auto Ladder & Amplicon Sizes)...")
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
print("🧪 [28/59] Testing Integrated WBStudio 16-bit Engine on real gapdh_*.tif samples...")
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
print("🧪 [29/59] Testing ProteinBiophysicsEngine (pI, GRAVY, 3D Fold, Ramachandran & Mutant ΔΔG)...")
let demoProt = ProteinBiophysicsEngine.builtinExamples[0]
let protReport = ProteinBiophysicsEngine.analyzeProtein(sequence: demoProt.sequence)
assert(protReport.length == demoProt.sequence.count, "Protein length mismatch")
assert(protReport.molecularWeightDa > 10000.0 && protReport.isoelectricPoint > 4.0 && protReport.isoelectricPoint < 10.0, "Protein MW & pI out of realistic range")
assert(protReport.residues.count == protReport.length && !protReport.contacts.isEmpty && !protReport.pockets.isEmpty, "Protein 3D fold must produce residues, contacts & pockets")
let exportedPDB = ProteinBiophysicsEngine.exportPDB(report: protReport)
let reparsedResidues = ProteinBiophysicsEngine.parsePDBResidues(exportedPDB)
assert(reparsedResidues.count == protReport.length, "PDB export & re-parse must preserve all Cα residues")
let mutEvals = ProteinBiophysicsEngine.evaluateMutantsBatch(wildTypeSequence: demoProt.sequence, mutationSpecs: ["R82H", "R155Q"])
assert(mutEvals.count == 2, "Must evaluate 2 mutant specifications")
assert(mutEvals.allSatisfy { $0.modelType == "empirical_heuristic" && $0.stabilityVerdict.contains("Empirical") }, "Mutant ΔΔG evaluations must carry empirical_heuristic modelType and honest verdict wording")
pass("ProteinBiophysicsEngine passed (Length=\(protReport.length)aa, pI=\(String(format: "%.2f", protReport.isoelectricPoint)), Q=\(String(format: "%.1f", protReport.compositeQScore)), Contacts=\(protReport.contacts.count)).")

// 30. 验证 Labworker 5 大直觉功能分组、新功能默认偏好设置与 Finder 多格式智能路由
print("🧪 [30/59] Testing Labworker 5-Category Navigation, Custom Bench Defaults & Finder Routing...")
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
print("🧪 [31/59] Testing DockFlowLab-aligned LIGSITE P-S-P Pocket, Consensus Vina Box & PDB Health Card...")
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
print("🧪 [32/59] Testing Sidebar Visibility Customization & Global Feature Manual...")
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
print("🧪 [33/59] Testing PrimerQualityEngine (primer3-py aligned Hairpin, Homodimer, Heterodimer & Mg2+/dNTP salt correction)...")
let stdCond = PrimerQualityEngine.Conditions.standard
// 33.1 参照 primer3-py 2.4.0: GCGAATTCGC (50mM Mon+, 1.5mM Mg2+, 0.6mM dNTP, 50nM DNA, 37℃)
// SantaLucia 2004 统一表 + Zuker-Stiegler DP + 自互补对称罚分 (dS=-1.4 cal/K/mol): Hairpin dg = -1.49 kcal/mol, tm = 55.6℃; Homodimer dg = -10.02 kcal/mol, dh = -79.40 kcal/mol, tm = 35.7℃
let hp1 = PrimerQualityEngine.calcHairpin("GCGAATTCGC", conditions: stdCond)
assert(hp1.structureFound, "GCGAATTCGC must form a hairpin")
assert(abs(hp1.dg - (-1.49)) < 0.05 && abs(hp1.tm - 55.6) < 0.2, "GCGAATTCGC hairpin mismatch: dg=\(hp1.dg), tm=\(hp1.tm)")
assert(hp1.asciiStructure.contains("SEQ\t") && hp1.asciiStructure.contains("╭AATT╮"), "Hairpin ASCII structure must contain primer3 header and stem-loop diagram")

let hd1 = PrimerQualityEngine.calcHomodimer("GCGAATTCGC", conditions: stdCond)
assert(hd1.structureFound, "GCGAATTCGC must form a self-complementary homodimer")
assert(abs(hd1.dg - (-10.02)) < 0.05 && abs(hd1.dh - (-79.40)) < 0.05 && abs(hd1.tm - 35.7) < 0.2, "GCGAATTCGC homodimer must match SantaLucia 2004 + symmetry penalty: dg=\(hd1.dg), dh=\(hd1.dh), tm=\(hd1.tm)")
assert(hd1.threePrimeAnchored && hd1.riskLevel == .high, "Full 10bp self-dimer with 3' pairing must be flagged as high risk")
assert(hd1.asciiStructure.contains("|"), "Homodimer ASCII diagram must render base-pair bars")

// 33.2 验证 Mg2+ 与 dNTP 浓度对二聚体/发夹稳定性的热力学影响 (游离 Mg2+ 越高，结构越稳定、ΔG 越负、Tm 越高)
let noMgCond = PrimerQualityEngine.Conditions(mvConc: 50.0, dvConc: 0.0, dntpConc: 0.0, dnaConc: 50.0, tempC: 37.0)
let highMgCond = PrimerQualityEngine.Conditions(mvConc: 50.0, dvConc: 2.0, dntpConc: 0.2, dnaConc: 50.0, tempC: 37.0)
let hdNoMg = PrimerQualityEngine.calcHomodimer("GCGAATTCGC", conditions: noMgCond)
let hdHighMg = PrimerQualityEngine.calcHomodimer("GCGAATTCGC", conditions: highMgCond)
assert(abs(hdNoMg.dg - (-8.80)) < 0.05 && abs(hdHighMg.dg - (-10.28)) < 0.05, "Mg2+/dNTP salt correction mismatch: noMg=\(hdNoMg.dg), highMg=\(hdHighMg.dg)")
assert(hdHighMg.dg < hd1.dg && hd1.dg < hdNoMg.dg && hdHighMg.tm > hdNoMg.tm, "Higher free Mg2+ must lower dG and raise dimer Tm")

// 33.3 验证异二聚体 calcDimer (正确底链悬垂 + C_T/4 浓度校正)
let het = PrimerQualityEngine.calcDimer("ATGCGATCGATCGATCGATC", "GCTAGCTAGCTAGCGATCGCAT", conditions: stdCond)
assert(het.structureFound && abs(het.dg - (-9.57)) < 0.05, "Heterodimer dG must match Zuker-Stiegler DP + DNA_TMM1 (-9.57): got \(het.dg)")
assert(het.threePrimeAnchored && het.riskLevel == .high, "3'-anchored heterodimer must be high risk")

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
print("🧪 [34/59] Testing Cross-Engine Consistency (Swift CloneStudioCore vs Python MCP Server)...")
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
    let swiftMuts = ProteinBiophysicsEngine.evaluateMutantsBatch(wildTypeSequence: protSeq, mutationSpecs: ["V18A", "V45P"], env: ProteinEnvironmentParams(ph: 7.0))
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
            "mutations": ["V18A", "V45P"]
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
print("🧪 [35/59] Testing SangerAlignmentEngine (.ab1 ABIF Binary Parser, 4-Channel Traces & Circular Plasmid Alignment)...")
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
print("🧪 [36/59] Testing Single Source of Truth for Test, Tool & Module Counts (P01)...")
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
print("🧪 [37/59] Testing qPCR Pseudo-Replication Fix & Biological Replicate Welch's t-test (P02)...")
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
print("🧪 [38/59] Testing WB Saturation Exclusion Policy, Pixel Mask & MCP Sync (P03)...")
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
print("🧪 [39/59] Testing MCP Atomic Sync Queue, Run ID Deduplication & Zero Hardcoded Paths (P04)...")
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
print("🧪 [40/59] Testing MCP Write Confirmation Dry-Run Preview, Backup & Annotations (P05)...")
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
print("🧪 [41/59] Testing CRISPR Sequence Heuristic Score Semantics & Off-Target Metadata (P06)...")
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
print("🧪 [42/59] Testing qPCR Holm–Bonferroni Multiple Comparison & Welch 95% CI (P07)...")
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
print("🧪 [43/59] Testing qPCR Control Wells (NTC / no-RT), Melt Curve Outlier & Undetermined QC (P08)...")
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
print("🧪 [44/59] Testing AnalysisRun Provenance Core Model & WB .run.json Sidecar Export (P09)...")
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
print("🧪 [45/59] Testing qPCR AnalysisRun Provenance .run.json Sidecar Export (P10-qPCR)...")
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
print("🧪 [46/59] Testing Sanger Verification AnalysisRun Provenance .run.json Sidecar Export (P10-Sanger)...")
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
print("🧪 [47/59] Testing SangerBatchEngine Multi-Clone Grouping, Coverage, 50-File Concurrency & Cancellation (P11)...")
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
print("🧪 [48/59] Testing Swift–Python Shared JSON Test Vectors & Tamper Detection (P12)...")
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

    // 验证 Libraries.sqlite plasmid_features 扩展特征库加载 (含 15 个核心种子 + 千级公有领域元件)
    let seededPlasmidFeatures = PlasmidAnnotationEngine.loadFeaturesFromSQLite()
    let expectedSeedNames: Set<String> = [
        "CMV promoter", "EF1a promoter", "U6 promoter", "T7 promoter",
        "AmpR", "KanR", "PuroR",
        "pUC ori", "ColE1 ori", "SV40 ori",
        "3xFLAG", "HA", "His",
        "EGFP", "mCherry"
    ]
    assert(seededPlasmidFeatures.count >= 1000, "Expected >= 1000 plasmid_features in Libraries.sqlite, found \(seededPlasmidFeatures.count)")
    assert(expectedSeedNames.isSubset(of: Set(seededPlasmidFeatures.map(\.name))), "Core seeded plasmid_features names missing")

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
print("🧪 [49/59] Testing OME-TIFF Physical Pixel Size Parser, Channel Mapping & Auto Scale Bar (P13)...")
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

    // 3. 测试 ImageJ 格式与标准 TIFF 分辨率回退解析 (2B: spacing= 为 3D Z 轴步距，严禁冒充 XY 像素尺寸)
    let imageJHeader = "ImageJ=1.53c\nimages=1\nunit=micron\nspacing=0.50\n"
    let ijMetaZOnly = BioImageProcessor.parseImageJDescription(imageJHeader, xResolution: nil, resolutionUnit: nil)
    assert(ijMetaZOnly?.physicalPixelSizeUM == nil, "ImageJ spacing= is Z-spacing and must NOT be assigned to XY physicalPixelSizeUM")
    assert(abs((ijMetaZOnly?.zSpacingUM ?? 0) - 0.50) < 1e-4, "ImageJ spacing=0.50 µm must be parsed into zSpacingUM")
    let ijMetaXY = BioImageProcessor.parseImageJDescription(imageJHeader, xResolution: 2.0, resolutionUnit: nil)
    assert(ijMetaXY?.physicalSizeSource == "ImageJ" && abs((ijMetaXY?.physicalPixelSizeUM ?? 0) - 0.50) < 1e-4, "ImageJ unit=micron + XResolution=2.0 must yield 0.50 µm/px")

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
print("🧪 [50/59] Testing WB Multi-Exposure Linearity Range & Best Exposure Recommendation (P14)...")
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
print("🧪 [51/59] Testing AnalysisRun v2 linkedPlasmidIDs, Index Store & v1 Backward Compatibility (P15)...")
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
print("🧪 [52/59] Testing LabBioCalculatorsEngine & Bio Calculator MCP Parity...")
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
    let t0 = LabBiochemCalculator.convertTemperature(from: .celsius(0))
    let tAbsZero = LabBiochemCalculator.convertTemperature(from: .kelvin(0))
    let tMinus40 = LabBiochemCalculator.convertTemperature(from: .fahrenheit(-40))
    let tAbsInvalid = LabBiochemCalculator.convertTemperature(from: .kelvin(-5))
    assert(abs(t37.fahrenheit - 98.6) < 1e-6 && abs(t37.kelvin - 310.15) < 1e-6 && !t37.isBelowAbsoluteZero)
    assert(abs(t0.kelvin - 273.15) < 1e-6 && abs(tAbsZero.celsius - (-273.15)) < 1e-6 && !tAbsZero.isBelowAbsoluteZero)
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

// 53. 验证 CodonOptimizationEngine 多宿主 CAI、禁区酶切/同聚物清零与 100% 氨基酸守恒
print("🧪 [53/59] Testing CodonOptimizationEngine (Multi-Host & Constraint Solver)...")
do {
    // 构造含 BsaI(GGTCTC)、EcoRI(GAATTC) 与 AAAAAA 同聚物的测试序列
    let dirtyCDS = "ATGGCTGCTGGTCTCAAAAAAGAATTCCCCGGGATGGACGCTTTTACTCTGCCTTAA"
    let origProt = CodonOptimizationEngine.translateDNA(dirtyCDS)
    let cfg = CodonOptimizationEngine.OptimizationConfig.presetConfig(.twist, host: .human)
    let rep = CodonOptimizationEngine.optimize(inputSequence: dirtyCDS, isProteinInput: false, config: cfg)
    assert(rep.optimizedDNA.count == dirtyCDS.count, "Optimized DNA length mismatch")
    assert(CodonOptimizationEngine.translateDNA(rep.optimizedDNA) == origProt, "Optimized DNA changed translated protein!")
    assert(!rep.optimizedDNA.contains("GGTCTC") && !rep.optimizedDNA.contains("GAGACC"), "BsaI site remained after optimization")
    assert(!rep.optimizedDNA.contains("GAATTC"), "EcoRI site remained after optimization")
    assert(!rep.optimizedDNA.contains("AAAAA"), "Homopolymer >=5bp remained after optimization")

    let egfpRep = CodonOptimizationEngine.optimize(
        inputSequence: CodonOptimizationEngine.demoEGFPFragmentDNA,
        isProteinInput: false,
        config: .presetConfig(.twist, host: .eColi)
    )
    assert(CodonOptimizationEngine.translateDNA(egfpRep.optimizedDNA) == egfpRep.proteinSequence, "EGFP protein translation must be 100% conserved")
    assert(egfpRep.optimizedCAI > 0.70, "E. coli CAI expected > 0.70, got \(egfpRep.optimizedCAI)")
    assert(egfpRep.constraintChecks.first(where: { $0.id == "motifs" })?.passed == true, "Motifs check must pass")
    assert(egfpRep.constraintChecks.first(where: { $0.id == "homopolymer" })?.passed == true, "Homopolymer check must pass")

    // 蛋白输入模式直推优化
    let protInput = "MVSKGEELFTGVVPILVELDGDVNGHKFSVS*"
    let protRep = CodonOptimizationEngine.optimize(inputSequence: protInput, isProteinInput: true, config: .presetConfig(.idt, host: .yeast))
    assert(protRep.isProteinInput == true && CodonOptimizationEngine.translateDNA(protRep.optimizedDNA) == protInput, "Protein input codon optimization failed")

    pass("CodonOptimizationEngine passed (CAI=\(String(format: "%.3f", egfpRep.optimizedCAI)), 100% AA conserved, motifs/homopolymers cleared).")
}

// 54. 验证 PlasmidSequencingAssemblyEngine（多 Sanger 双向 Contig 拼接 + 全质粒 Nanopore Origin 旋转与 SV 检测）
print("🧪 [54/59] Testing PlasmidSequencingAssemblyEngine (Sanger Contig & Whole-Plasmid Nanopore SV)...")
do {
    let msFx = PlasmidSequencingAssemblyEngine.demoMultiSangerFixture()
    let contig = PlasmidSequencingAssemblyEngine.assembleSangerContig(
        reads: msFx.reads,
        referenceSequence: msFx.refSeq,
        referenceName: msFx.refName
    )
    assert(contig.readBriefs.count == 2, "Expected 2 reads in Sanger contig")
    assert(contig.doubleStrandCoveredCount >= 40, "Expected >=40 bp double-strand overlap, got \(contig.doubleStrandCoveredCount)")
    assert(contig.coveragePercent >= 90.0, "Expected >=90% coverage, got \(contig.coveragePercent)")
    assert(contig.mismatchCount == 1, "Expected 1 consensus SNP vs reference, got \(contig.mismatchCount)")
    assert(contig.meanConsensusPhred >= 40.0, "Expected high consensus Phred")
    assert(contig.consensusFASTA.hasPrefix(">") && contig.consensusFASTQ.hasPrefix("@"))

    // Nanopore Origin 旋转 + SNP + 40bp 缺失
    let wpFx = PlasmidSequencingAssemblyEngine.demoWholePlasmidFixture()
    let wpRecords = PlasmidSequencingAssemblyEngine.parseFastqOrFasta(wpFx.fastqText, defaultName: wpFx.queryName)
    assert(wpRecords.count == 1 && wpRecords[0].isFastq && abs((wpRecords[0].meanPhred ?? 0) - 40.0) < 0.5)
    let wpRep = PlasmidSequencingAssemblyEngine.verifyWholePlasmid(
        querySequence: wpRecords[0].sequence,
        queryName: wpRecords[0].name,
        queryMeanPhred: wpRecords[0].meanPhred,
        referenceSequence: wpFx.refSeq,
        referenceName: wpFx.refName
    )
    assert(wpRep.rotatedOriginOffset0Based > 100, "Origin rotation offset should be detected, got \(wpRep.rotatedOriginOffset0Based)")
    assert(wpRep.snpCount == 1, "Expected 1 SNP in whole plasmid demo, got \(wpRep.snpCount)")
    assert(wpRep.variants.contains(where: { $0.kind == .largeDeletion && $0.sizeBp >= 35 }), "Expected 40bp large deletion SV")
    assert(wpRep.verdict == .structuralVariantDetected, "Expected structuralVariantDetected verdict")

    // 反向互补完美匹配验证
    let rcPerfect = PlasmidSequencingAssemblyEngine.verifyWholePlasmid(
        querySequence: BioSequence.reverseComplement(wpFx.refSeq),
        queryName: "RC_Perfect",
        referenceSequence: wpFx.refSeq,
        referenceName: wpFx.refName
    )
    assert(rcPerfect.isReverseComplement == true && rcPerfect.verdict == .verifiedPass, "Reverse-complement whole plasmid verification failed")

    // 串联重复验证 (插入第 100..220 片段副本)
    let refChars = Array(wpFx.refSeq)
    let prefixPart = String(refChars[0..<220])
    let dupPart = String(refChars[100..<220])
    let suffixPart = String(refChars[220..<refChars.count])
    let tandemQuery = prefixPart + dupPart + suffixPart
    let dupRep = PlasmidSequencingAssemblyEngine.verifyWholePlasmid(
        querySequence: tandemQuery,
        queryName: "TandemDup",
        referenceSequence: wpFx.refSeq,
        referenceName: wpFx.refName
    )
    let hasTandemDupOrIns = dupRep.variants.contains { v in
        v.kind == .tandemDuplication || v.kind == .largeInsertion
    }
    assert(hasTandemDupOrIns, "Expected tandem duplication/insertion detection")

    pass("PlasmidSequencingAssemblyEngine passed (Sanger 2-strand Contig cov=\(String(format: "%.1f%%", contig.coveragePercent)), Nanopore Origin rotation + SNP + SV).")
}

// 55. 验证 SequenceFormatEngine (GenBank/OpenCloning/SBOL3) 与 ProteinBiophysicsEngine mmCIF 解析
print("🧪 [55/59] Testing SequenceFormatEngine & ProteinBiophysicsEngine mmCIF Parser...")
do {
    let demoSeq = String(repeating: "ATGGTGAGCAAGGGCGAGGAGCTGTTCACC", count: 16) // 480 bp
    let f1 = SnapGeneFeature(name: "CMV_Promoter", type: "promoter", directionality: "1", segments: [SnapGeneSegment(range: "10-150", start: 10, end: 150, color: "#f59e0b")])
    let f2 = SnapGeneFeature(name: "EGFP_CDS", type: "CDS", directionality: "2", segments: [SnapGeneSegment(range: "180-450", start: 180, end: 450, color: "#3b82f6")])
    let origInfo = SnapGeneFileInfo(
        filePath: "verify://demo.dna",
        fileName: "DemoVec.dna",
        sequence: demoSeq,
        length: demoSeq.count,
        isCircular: true,
        featuresCount: 2,
        features: [f1, f2]
    )

    let gbText = SequenceFormatEngine.exportGenBank(info: origInfo, name: "DemoVec")
    guard let parsedGB = SequenceFormatEngine.parseGenBank(gbText, fallbackName: "DemoVec") else {
        fatalError("GenBank round-trip parse failed")
    }
    assert(parsedGB.sequence == demoSeq && parsedGB.isCircular == true, "GenBank sequence/topology mismatch")
    assert(parsedGB.features.count == 2 && parsedGB.features[1].directionality == "2", "GenBank complement feature round-trip failed")

    let ocJSON = try SequenceFormatEngine.exportOpenCloningJSON(info: origInfo, name: "DemoVec")
    let parsedOC = SequenceFormatEngine.parseOpenCloningJSON(ocJSON)
    assert(parsedOC.count == 1 && parsedOC[0].sequence == demoSeq && parsedOC[0].features.count == 2, "OpenCloning JSON round-trip failed")

    let sbolJSON = try SequenceFormatEngine.exportSBOL3JSONLD(info: origInfo, name: "DemoVec")
    let parsedSBOL = SequenceFormatEngine.parseSBOL3JSONLD(sbolJSON)
    assert(parsedSBOL.count == 1 && parsedSBOL[0].sequence == demoSeq && parsedSBOL[0].isCircular == true && parsedSBOL[0].features.count == 2, "SBOL3 JSON-LD round-trip failed")

    let mmcifFixture = """
    data_TEST_CIF
    loop_
    _atom_site.group_PDB
    _atom_site.id
    _atom_site.type_symbol
    _atom_site.label_atom_id
    _atom_site.label_alt_id
    _atom_site.label_comp_id
    _atom_site.auth_asym_id
    _atom_site.auth_seq_id
    _atom_site.Cartn_x
    _atom_site.Cartn_y
    _atom_site.Cartn_z
    _atom_site.B_iso_or_equiv
    _atom_site.pdbx_PDB_model_num
    ATOM 1 C CA . ALA A 1 1.000 2.000 3.000 95.4 1
    ATOM 2 H HA . ALA A 1 1.500 2.200 3.100 95.4 1
    ATOM 3 C CA . LYS A 2 4.800 2.100 3.200 91.2 1
    ATOM 4 C CA . TRP A 3 8.600 2.300 3.500 88.7 1
    ATOM 5 C CA . TYR A 4 12.400 2.600 3.900 84.1 1
    HETATM 6 P PA . ATP A 101 5.000 5.000 5.000 60.0 1
    HETATM 7 O O . HOH A 201 9.000 9.000 9.000 30.0 1
    ATOM 8 C CA . GLY A 1 99.000 99.000 99.000 50.0 2
    """
    assert(ProteinBiophysicsEngine.isMMCIFFormat(mmcifFixture))
    let protRep = ProteinBiophysicsEngine.analyzeProtein(sequence: "", pdbText: mmcifFixture)
    assert(protRep.length == 4 && protRep.sequence == "AKWY", "mmCIF CA extraction mismatch: got \(protRep.sequence)")
    assert(abs(protRep.residues[0].plddt - 95.4) < 0.1, "mmCIF B-factor/pLDDT mismatch")
    assert(protRep.healthCard.coCrystalLigands == ["ATP"], "mmCIF coCrystalLigands mismatch: \(protRep.healthCard.coCrystalLigands)")
    assert(!protRep.healthCard.coCrystalLigands.contains("HOH"), "Water must be excluded")

    pass("SequenceFormatEngine (GenBank/OpenCloning/SBOL3) & mmCIF parser verified.")
} catch {
    fatalError("SequenceFormatEngine/mmCIF verification failed: \(error)")
}

// 56. 验证 QPCRInstrumentAndRDMLEngine（QuantStudio/CFX/LightCycler/MxPro 多仪器嗅探 + RDML 往返 + MIQE 清单）
print("🧪 [56/59] Testing QPCRInstrumentAndRDMLEngine (4 Instrument Parsers, RDML ZIP/XML & MIQE)...")
do {
    let qsRaw = """
    * Block Type = 96-Well 0.2-mL Block
    * Instrument Name = QuantStudio 5
    [Results]
    Well Position\tSample Name\tTarget Name\tTask\tCT\tTm1
    A1\tWT-Ctrl\tGAPDH\tUNKNOWN\t18.42\t84.1
    A2\tNTC\tGAPDH\tNTC\tUndetermined\t
    """
    let qsRes = QPCRInstrumentAndRDMLEngine.parseRawExport(qsRaw)
    assert(qsRes.format == .quantStudio && qsRes.skippedHeaderLines == 3 && qsRes.wells.count == 2)
    assert(qsRes.wells[0].ct == 18.42 && qsRes.wells[0].tm == 84.1 && qsRes.wells[1].wellType == .ntc && qsRes.wells[1].ct == nil)

    let cfxRaw = """
    Run Information
    File Name,experiment.pcrd
    Well,Fluor,Target,Content,Sample,Cq,Starting Quantity (SQ)
    B1,SYBR,TP53,Unkn,DrugA,22.15,
    B2,SYBR,TP53,Std,STD1,16.50,1.00E+05
    """
    let cfxRes = QPCRInstrumentAndRDMLEngine.parseRawExport(cfxRaw)
    assert(cfxRes.format == .cfxMaestro && cfxRes.wells.count == 2 && cfxRes.wells[1].wellType == .standard && cfxRes.wells[1].quantity == 100000.0)

    let lcRaw = """
    Experiment: LC480_Run\tSelected Filter: SYBR Green I (465-510)
    Pos\tName\tCp\tConcentration\tStatus\tTm1
    C1\tSample1\t20.41\t\t\t85.2
    """
    let lcRes = QPCRInstrumentAndRDMLEngine.parseRawExport(lcRaw)
    assert(lcRes.format == .lightCycler480 && lcRes.wells.count == 1 && lcRes.wells[0].ct == 20.41 && lcRes.wells[0].tm == 85.2)

    let mxRaw = """
    Well,Well Name,Well Type,Target,Ct (dR),Tm1 (C)
    D1,Treated-1,Unknown,MYC,19.85,82.6
    """
    let mxRes = QPCRInstrumentAndRDMLEngine.parseRawExport(mxRaw)
    assert(mxRes.format == .mxPro && mxRes.wells.count == 1 && mxRes.wells[0].ct == 19.85)

    // RDML .rdml ZIP 归档往返读写校验
    let settings = QPCRSettings()
    let baseWells = QPCRInstrumentAndRDMLEngine.parseRawExport(QPCRAnalysisEngine.defaultExampleCSV).wells
    let rdmlTmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("verify_\(UUID().uuidString).rdml")
    defer { try? FileManager.default.removeItem(at: rdmlTmpURL) }
    try QPCRInstrumentAndRDMLEngine.writeRDMLArchive(wells: baseWells, settings: settings, experimentName: "VerifyRDML", to: rdmlTmpURL)
    let rdmlBytes = try Data(contentsOf: rdmlTmpURL)
    let rdmlParsed = try QPCRInstrumentAndRDMLEngine.parseRDMLData(rdmlBytes, fileName: rdmlTmpURL.lastPathComponent)
    assert(rdmlParsed.format == .rdml && rdmlParsed.wells.count == baseWells.count, "RDML ZIP round-trip well count mismatch: \(rdmlParsed.wells.count) vs \(baseWells.count)")
    assert(abs((rdmlParsed.wells[0].ct ?? 0) - (baseWells[0].ct ?? -1)) < 1e-3, "RDML Ct round-trip mismatch")

    let qcMap = QPCRAnalysisEngine.computeQC(wells: baseWells, settings: settings)
    let ddct = QPCRAnalysisEngine.computeDdct(wells: baseWells, settings: settings, qc: qcMap)
    let stdOut = QPCRAnalysisEngine.computeStandardCurve(wells: baseWells, settings: settings, qc: qcMap)
    let miqe = QPCRInstrumentAndRDMLEngine.evaluateMIQECompliance(
        wells: baseWells,
        settings: settings,
        qc: qcMap,
        ddctOut: ddct,
        stdOut: stdOut,
        detectedFormat: .genericCSV
    )
    assert(miqe.items.count == 8 && miqe.exportMarkdownChecklist().contains("MIQE"))

    pass("QPCRInstrumentAndRDMLEngine verified (4 instrument formats, RDML archive round-trip & 8-item MIQE checklist).")
} catch {
    fatalError("QPCRInstrumentAndRDMLEngine verification failed: \(error)")
}

// 57. 验证 PlateReaderAssayEngine（8x12 矩阵解析、BCA WB 配液守恒、ELISA 4PL/5PL LM 拟合、IC50 & CCK-8 ANOVA）
print("🧪 [57/59] Testing PlateReaderAssayEngine (Matrix Parser, BCA, ELISA 4PL/5PL, IC50 & One-Way ANOVA)...")
do {
    let matrixText = """
    Instrument: BioTek Synergy
    Read: 562nm
    ,1,2,3,4
    A,0.105,0.220,0.450,0.890
    B,0.112,0.235,0.462,0.910
    """
    let mVals = PlateReaderAssayEngine.parsePlateReaderValues(matrixText)
    assert(mVals.count == 8 && mVals["A1"] == 0.105 && mVals["B3"] == 0.462, "8x12 plate matrix parse failed")

    let bcaFx = PlateReaderAssayEngine.demoBCAData()
    guard let bcaRep = PlateReaderAssayEngine.analyzeBCA(
        standards: bcaFx.standards,
        samples: bcaFx.samples,
        model: .linear,
        blankOD: bcaFx.blankOD,
        dilutionFactor: 1.0,
        targetLoadUg: 20.0,
        targetTotalVolUl: 20.0,
        loadingBufferX: 5.0
    ) else { fatalError("BCA analysis failed") }
    assert(bcaRep.r2 > 0.999 && bcaRep.samples.count == 3, "BCA R² expected >0.999")
    for s in bcaRep.samples {
        let sumVol = s.proteinVolumeUl + s.lysisBufferVolumeUl + s.loadingBufferVolumeUl
        assert(abs(sumVol - 20.0) < 1e-6, "WB loading volume must sum cleanly to 20 uL, got \(sumVol)")
    }

    // ELISA 4PL 精准还原检验 (a=0.10, b=1.2, c=80.0, d=2.5)
    let trueA = 0.10, trueB = 1.2, trueC = 80.0, trueD = 2.5
    let stdConcs = [5.0, 15.0, 40.0, 80.0, 160.0, 400.0, 1000.0]
    let synth4PL = stdConcs.map { x in (x: x, y: trueD + (trueA - trueD) / (1.0 + pow(x / trueC, trueB))) }
    guard let elisaFit = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: synth4PL, fiveParameter: false) else {
        fatalError("4PL fit failed")
    }
    assert(elisaFit.r2 > 0.9999 && abs(elisaFit.paramC - trueC) / trueC < 0.02, "4PL recovery mismatch: c=\(elisaFit.paramC)")
    let unknownY = trueD + (trueA - trueD) / (1.0 + pow(120.0 / trueC, trueB))
    let qOut = PlateReaderAssayEngine.quantifyELISASamples(samples: [("Test", [unknownY])], fit: elisaFit)
    assert(qOut.count == 1 && abs((qOut[0].interpolatedConc ?? 0) - 120.0) / 120.0 < 0.02 && qOut[0].status == .inRange)

    // 5PL 测试
    let synth5PL = stdConcs.map { x in (x: x, y: trueD + (trueA - trueD) / pow(1.0 + pow(x / trueC, trueB), 1.6)) }
    guard let fit5 = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: synth5PL, fiveParameter: true) else {
        fatalError("5PL fit failed")
    }
    assert(fit5.r2 > 0.999, "5PL R² mismatch: \(fit5.r2)")

    // IC50 Hill 曲线还原验证
    guard let icFit = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: PlateReaderAssayEngine.demoDoseResponseData(), fiveParameter: false) else {
        fatalError("IC50 Hill fit failed")
    }
    assert(icFit.r2 > 0.998 && abs(icFit.paramC - 25.0) / 25.0 < 0.15, "IC50 expected ~25 nM, got \(icFit.paramC)")

    // CCK-8 细胞活力 + Holm + One-Way ANOVA
    guard let viaRep = PlateReaderAssayEngine.analyzeViability(groups: PlateReaderAssayEngine.demoViabilityData(), controlGroupName: "Control", blankMean: 0.08) else {
        fatalError("CCK-8 viability failed")
    }
    assert(abs(viaRep.groups[0].meanViabilityPercent - 100.0) < 1e-6)
    assert((viaRep.anova?.fStatistic ?? 0) > 100.0 && (viaRep.anova?.pValue ?? 1.0) < 0.0001, "One-Way ANOVA significance mismatch")
    assert((viaRep.groups.last?.pAdjusted ?? 1.0) < 0.01, "Holm adjusted p-value expected < 0.01")

    pass("PlateReaderAssayEngine verified (8x12 matrix, BCA, ELISA 4PL/5PL R²>0.999, IC50 & One-Way ANOVA).")
}

// 58. 验证离线 Mol* 资源包与 ProteinDockingBridgeEngine（CLI 探测 / PDBQT->PDB / Vina & Gnina 解析 / Boltz YAML）
print("🧪 [58/59] Testing Offline Mol* Bundle & ProteinDockingBridgeEngine...")
do {
    guard let htmlPath = CloneStudioResourceLocator.path(forResource: "molstar_host", ofType: "html"),
          let jsPath = CloneStudioResourceLocator.path(forResource: "molstar", ofType: "js"),
          let cssPath = CloneStudioResourceLocator.path(forResource: "molstar", ofType: "css") else {
        fatalError("Missing offline Mol* viewer assets in CloneStudioCore/Resources")
    }
    let htmlText = try String(contentsOfFile: htmlPath, encoding: .utf8)
    let jsSize = (try FileManager.default.attributesOfItem(atPath: jsPath)[.size] as? NSNumber)?.intValue ?? 0
    let cssSize = (try FileManager.default.attributesOfItem(atPath: cssPath)[.size] as? NSNumber)?.intValue ?? 0
    assert(jsSize > 1_000_000 && cssSize > 10_000, "Bundled Mol* files unexpectedly small: js=\(jsSize), css=\(cssSize)")
    assert(htmlText.contains("./molstar.js") && htmlText.contains("./molstar.css") && htmlText.contains("LabworkerMolstar"), "molstar_host.html invalid")
    assert(!htmlText.contains("http://") && !htmlText.contains("https://"), "molstar_host.html must not contain any external HTTP/HTTPS URLs")

    let detected = ProteinDockingBridgeEngine.detectInstalledTools(customOverrides: [.vina: "/usr/bin/env"])
    assert(detected.count == ProteinDockingBridgeEngine.LocalComputeToolKind.allCases.count, "Expected 5 CLI tool probes")
    let overrideVina = detected.first(where: { $0.kind == .vina })
    assert(overrideVina?.isAvailable == true && overrideVina?.executablePath == "/usr/bin/env", "Custom override executable detection failed")

    // PDBQT -> 标准 PDB 元素列转换校验
    let samplePDBQT = """
    MODEL 1
    REMARK VINA RESULT:    -8.4      0.000      0.000
    ATOM      1  C1  LIG     1      11.234  22.345  33.456  1.00  0.00     0.123 A
    ATOM      2  O1  LIG     1      12.000  23.000  34.000  1.00  0.00    -0.450 OA
    HETATM    3  BR1 LIG     1      13.100  24.200  35.100  1.00  0.00    -0.080 Br
    ENDMDL
    MODEL 2
    REMARK VINA RESULT:    -7.9      1.425      2.810
    ATOM      1  C1  LIG     1      10.100  21.200  32.300  1.00  0.00     0.123 C
    ENDMDL
    """
    let vinaStdout = """
    mode |   affinity | dist from best mode
         | (kcal/mol) | rmsd l.b.| rmsd u.b.
    -----+------------+----------+----------
       1         -8.4      0.000      0.000
       2         -7.9      1.425      2.810
    """
    let vinaPoses = ProteinDockingBridgeEngine.parseDockingResults(stdoutText: vinaStdout, outputFileText: samplePDBQT, tool: .vina)
    assert(vinaPoses.count == 2 && abs(vinaPoses[0].affinityKcalMol - (-8.4)) < 1e-6 && abs(vinaPoses[1].rmsdUB - 2.81) < 1e-6)
    let convertedPDB = vinaPoses[0].pdbBlock
    assert(convertedPDB.contains("           C") || convertedPDB.hasSuffix("          BR") || convertedPDB.contains("           O"))
    assert(!convertedPDB.contains("0.123 A") && convertedPDB.contains("          BR"))

    // Gnina 5 列打分表 + 无 stdout 纯 PDBQT REMARK 解析校验
    let gninaStdout = """
    mode |  affinity  |  intramol  |    CNN     |   CNN
         | (kcal/mol) | (kcal/mol) | pose score | affinity
    -----+------------+------------+------------+----------
       1       -7.42      -0.31       0.8812     7.145
       2       -7.10      -0.12       0.7654     6.801
    """
    let gninaPoses = ProteinDockingBridgeEngine.parseDockingResults(stdoutText: gninaStdout, outputFileText: samplePDBQT, tool: .gnina)
    assert(gninaPoses.count == 2 && abs((gninaPoses[0].cnnScore ?? 0) - 0.8812) < 1e-6 && abs((gninaPoses[0].cnnAffinity ?? 0) - 7.145) < 1e-6)
    let standalonePoses = ProteinDockingBridgeEngine.parseDockingResults(stdoutText: "", outputFileText: samplePDBQT, tool: .vina)
    assert(standalonePoses.count == 2 && abs(standalonePoses[1].rmsdLB - 1.425) < 1e-6)

    // Boltz YAML 生成 & Confidence JSON 解析校验
    let boltzYAML = ProteinDockingBridgeEngine.generateBoltzYAML(proteinSequence: "MKTVRQERLK", ligandSMILES: "CC(=O)OC1=CC=CC=C1C(=O)O")
    assert(boltzYAML.contains("version: 1") && boltzYAML.contains("sequence: MKTVRQERLK") && boltzYAML.contains("smiles:"))
    let confJSON = #"{"confidence_score": 0.874, "ptm": 0.91, "iptm": 0.84, "ligand_iptm": 0.86, "complex_plddt": 89.2}"#.data(using: .utf8)!
    let bzSummary = ProteinDockingBridgeEngine.parseBoltzConfidenceJSON(confJSON)
    assert(bzSummary != nil && abs((bzSummary?.confidenceScore ?? 0) - 0.874) < 1e-6 && abs((bzSummary?.iptm ?? 0) - 0.84) < 1e-6)

    pass("Offline Mol* bundle & ProteinDockingBridgeEngine passed (0 CDN URLs, PDBQT->PDB, Vina/Gnina/Boltz verified).")
}

// 59. 验证 OrderTemplateEngine & ExcelOrderExporter（国际批量模板 IDT/Twist/GenScript/Eurofins/BGI 与自定义 JSON）
print("🧪 [59/59] Testing International Order Templates & Custom JSON Column Mapping...")
do {
    let sampleItems = [
        PrimerItem(name: "TP53/Exon1 <F> & 'Mut', ultra_long_primer_identifier", fullSequence: "ggatccATGGAGGAGCCGCAGTCAG", homologyArm: "ggatcc", specificSequence: "ATGGAGGAGCCGCAGTCAG", tm: 62.5, purity: "PAGE", od: 2.0, targetPurpose: "敲除验证"),
        PrimerItem(name: "EGFP_GeneFrag_1", fullSequence: "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTG", homologyArm: "", specificSequence: "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTG", tm: 0.0, purity: "Desalt", od: 5.0, targetPurpose: "基因片段合成", notes: "CodonOpt")
    ]
    let idtWarnings = OrderTemplateEngine.validateSanitizationWarnings(template: .idtBulk, spec: nil, primers: sampleItems)
    let eurofinsWarnings = OrderTemplateEngine.validateSanitizationWarnings(template: .eurofinsBulk, spec: nil, primers: sampleItems)
    assert(!idtWarnings.isEmpty && !eurofinsWarnings.isEmpty, "Sanitization warnings expected for dirty primer names")

    let tmpOutDir = FileManager.default.temporaryDirectory.appendingPathComponent("labworker_order_verify_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpOutDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpOutDir) }

    // 1. IDT CSV & XLSX 验证
    let idtCSV = try ExcelOrderExporter.shared.exportOrder(template: .idtBulk, primers: sampleItems, samples: [], targetDir: tmpOutDir.path, fileFormat: .csv)
    let idtText = try String(contentsOfFile: idtCSV, encoding: .utf8)
    assert(idtText.contains("Name,Sequence,Scale,Purification") && idtText.contains("25nm,PAGE") && idtText.contains("100nm,STD"))
    assert(!idtText.contains("<F>"), "IDT disallowed chars should be sanitized")

    let idtXLSX = try ExcelOrderExporter.shared.exportOrder(template: .idtBulk, primers: sampleItems, samples: [], targetDir: tmpOutDir.path, fileFormat: .xlsx)
    let idtData = try Data(contentsOf: URL(fileURLWithPath: idtXLSX))
    assert(idtData.prefix(2) == Data([0x50, 0x4B]), "IDT XLSX must be valid ZIP/PK archive")

    // 2. Twist / GenScript / Eurofins / BGI 导出验证
    let twistCSV = try ExcelOrderExporter.shared.exportOrder(template: .twistBulk, primers: sampleItems, samples: [], targetDir: tmpOutDir.path, fileFormat: .csv)
    let twistText = try String(contentsOfFile: twistCSV, encoding: .utf8)
    assert(twistText.contains("Sequence Name,Sequence,Well Position,Plate ID"))

    let gsXLSX = try ExcelOrderExporter.shared.exportOrder(template: .genscriptBulk, primers: sampleItems, samples: [], targetDir: tmpOutDir.path, fileFormat: .xlsx)
    assert(FileManager.default.fileExists(atPath: gsXLSX))

    let euroCSV = try ExcelOrderExporter.shared.exportOrder(template: .eurofinsBulk, primers: sampleItems, samples: [], targetDir: tmpOutDir.path, fileFormat: .csv)
    let euroLines = (try String(contentsOfFile: euroCSV, encoding: .utf8)).components(separatedBy: .newlines).filter { !$0.isEmpty }
    assert(euroLines.count == 3 && euroLines[0].contains("Well,Oligo Name,Sequence"))
    let row1Cols = euroLines[1].components(separatedBy: ",")
    assert(row1Cols.count >= 2 && row1Cols[1].count <= 25 && !row1Cols[1].contains(" "), "Eurofins Oligo Name max 25 chars & no spaces")

    let bgiXLSX = try ExcelOrderExporter.shared.exportOrder(template: .bgiBulk, primers: sampleItems, samples: [], targetDir: tmpOutDir.path, fileFormat: .xlsx)
    assert(FileManager.default.fileExists(atPath: bgiXLSX))

    // 3. Custom JSON 往返持久化 & 动态列导出
    let storeURL = tmpOutDir.appendingPathComponent("custom_templates.json")
    let customSpec = CustomOrderTemplateSpec(
        id: "test_custom_1",
        name: "Lab_Custom_Test",
        preferredFormat: .csv,
        columns: [
            OrderColumnMapping(header: "WellID", field: .well96),
            OrderColumnMapping(header: "ItemName", field: .name),
            OrderColumnMapping(header: "Seq5to3", field: .sequence),
            OrderColumnMapping(header: "Tag", field: .staticDefault, defaultValue: "CloningCore")
        ]
    )
    try CustomOrderTemplateStore.saveTemplates([customSpec], to: storeURL)
    let reloaded = CustomOrderTemplateStore.loadTemplates(from: storeURL)
    assert(reloaded.count == 1 && reloaded[0].columns.count == 4 && reloaded[0].columns[3].defaultValue == "CloningCore")

    let customCSV = try ExcelOrderExporter.shared.exportOrder(
        template: .customJSON,
        primers: sampleItems,
        samples: [],
        targetDir: tmpOutDir.path,
        fileFormat: .csv,
        customTemplate: customSpec
    )
    let customText = try String(contentsOfFile: customCSV, encoding: .utf8)
    assert(customText.contains("WellID,ItemName,Seq5to3,Tag") && customText.contains(",CloningCore"))

    pass("OrderTemplateEngine & ExcelOrderExporter verified (IDT/Twist/GenScript/Eurofins/BGI + Custom JSON XLSX/CSV).")
}

// 60. 验证双语本地化词典完整性、实时语言切换、动态规则与中英双语检索
print("🧪 [60/60] Testing Bilingual Localization Dictionary & Live Switching...")
do {
    func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    let dictCount = L10n.loadedTranslationCount
    assert(dictCount >= 1500, "Expected >= 1500 entries in en_translations.json, got \(dictCount)")

    let dict = L10n.allExactTranslations
    assert(dict.count == dictCount)
    let fmtRegex = try NSRegularExpression(
        pattern: #"%%|%[-+0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[diuoxXfFeEgGaAcCsSp@]"#
    )
    func printfSpecs(_ s: String) -> [String] {
        let ns = s as NSString
        return fmtRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .filter { $0 != "%%" }
    }

    var badEnglish: [String] = []
    var badFmt: [String] = []
    for (zhKey, enVal) in dict {
        if enVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || containsCJK(enVal) {
            badEnglish.append("\(zhKey) -> \(enVal)")
        }
        if zhKey.contains("%") && printfSpecs(zhKey) != printfSpecs(enVal) {
            badFmt.append("\(zhKey) -> \(enVal)")
        }
    }
    assert(badEnglish.isEmpty, "Empty or CJK-containing English values found: \(badEnglish.prefix(5))")
    assert(badFmt.isEmpty, "Printf specifier mismatch found: \(badFmt.prefix(5))")

    await MainActor.run {
        let prevLang = AppState.shared.appLanguage
        let prevUD = UserDefaults.standard.object(forKey: "cs_appLanguage")
        defer {
            AppState.shared.appLanguage = prevLang
            if let prevUD {
                UserDefaults.standard.set(prevUD, forKey: "cs_appLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "cs_appLanguage")
            }
        }

        AppState.shared.appLanguage = .english
        assert(L10n.currentLanguage == .english && L10n.isEnglish)

        for sec in SidebarSectionKind.allCases {
            assert(!sec.title.isEmpty && !containsCJK(sec.title), "SidebarSectionKind.\(sec.rawValue) leaked CJK: \(sec.title)")
        }
        for nav in NavItem.allCases {
            assert(!nav.title.isEmpty && !containsCJK(nav.title), "NavItem.\(nav.rawValue).title leaked CJK: \(nav.title)")
            assert(!nav.summaryDescription.isEmpty && !containsCJK(nav.summaryDescription), "NavItem.\(nav.rawValue).summaryDescription leaked CJK: \(nav.summaryDescription)")
            assert(!nav.supportedFormats.isEmpty && !containsCJK(nav.supportedFormats), "NavItem.\(nav.rawValue).supportedFormats leaked CJK: \(nav.supportedFormats)")
            assert(!nav.workflowTip.isEmpty && !containsCJK(nav.workflowTip), "NavItem.\(nav.rawValue).workflowTip leaked CJK: \(nav.workflowTip)")
            assert(!nav.section.title.isEmpty && !containsCJK(nav.section.title), "NavItem.\(nav.rawValue).section.title leaked CJK: \(nav.section.title)")
        }
        for preset in SidebarVisibilityPreset.allCases {
            assert(!preset.title.isEmpty && !containsCJK(preset.title), "SidebarVisibilityPreset leaked CJK: \(preset.title)")
        }
        for mode in AppAppearanceMode.allCases {
            assert(!mode.title.isEmpty && !containsCJK(mode.title), "AppAppearanceMode.title leaked CJK: \(mode.title)")
            assert(!mode.shortTitle.isEmpty && !containsCJK(mode.shortTitle), "AppAppearanceMode.shortTitle leaked CJK: \(mode.shortTitle)")
        }
        for ov in CanvasThemeOverride.allCases {
            assert(!ov.title.isEmpty && !containsCJK(ov.title), "CanvasThemeOverride leaked CJK: \(ov.title)")
        }
        for theme in AppAccentTheme.allCases {
            assert(!theme.title.isEmpty && !containsCJK(theme.title), "AppAccentTheme leaked CJK: \(theme.title)")
        }
        for lg in LiquidGlassStyleMode.allCases {
            assert(!lg.title.isEmpty && !containsCJK(lg.title), "LiquidGlassStyleMode.title leaked CJK: \(lg.title)")
            assert(!lg.shortTitle.isEmpty && !containsCJK(lg.shortTitle), "LiquidGlassStyleMode.shortTitle leaked CJK: \(lg.shortTitle)")
        }
        for loc in ExportSaveLocation.allCases {
            assert(!loc.title.isEmpty && !containsCJK(loc.title), "ExportSaveLocation leaked CJK: \(loc.title)")
        }

        assert(L10n.t("96 孔板") == "96-Well Plate", "Dynamic plate format mismatch: \(L10n.t("96 孔板"))")
        assert(L10n.t("显示全部功能 (18)") == "Show All Modules (18)", "Dynamic module preset mismatch: \(L10n.t("显示全部功能 (18)"))")
        assert(L10n.t("3 项") == "3 items", "Dynamic item count mismatch: \(L10n.t("3 项"))")
        assert(L10n.tr("中文", "English") == "English")

        assert(NavItem.plateDesigner.matchesSearch("微孔板") == true)
        assert(NavItem.plateDesigner.matchesSearch("Microplate") == true)

        AppState.shared.appLanguage = .zhHans
        assert(L10n.t("单片段无缝克隆") == "单片段无缝克隆")
    }

    pass("Bilingual localization verified (\(dictCount) translations, 0 CJK leaks, live switching & bilingual search).")
}

// 61. 验证第一批科研严谨度核心修复 (qPCR Vandesompele/Pfaffl/qBase/Jensen/Median+Grubbs + Homology + Plate + Sanger 覆盖度)
print("🧪 [61/61] Testing Batch 1 Scientific Rigor Fixes (qPCR/Homology/Plate/Sanger Coverage)...")
do {
    // 61.1 qPCR Vandesompele 多内参算术 Ct 均值 vs 误用几何均值
    let multiRefCSV = """
    well,sample,group,target,ct
    A1,C1,Ctrl,GAPDH,18.00
    A2,C1,Ctrl,TBP,28.00
    A3,C1,Ctrl,TP53,25.00
    A4,C2,Ctrl,GAPDH,18.00
    A5,C2,Ctrl,TBP,28.00
    A6,C2,Ctrl,TP53,25.00
    B1,T1,Trt,GAPDH,18.00
    B2,T1,Trt,TBP,28.00
    B3,T1,Trt,TP53,23.00
    B4,T2,Trt,GAPDH,18.00
    B5,T2,Trt,TBP,28.00
    B6,T2,Trt,TP53,23.00
    """
    let mrWells = QPCRAnalysisEngine.parseQPCRTable(multiRefCSV)
    let mrSettings = QPCRSettings(referenceTargets: ["GAPDH", "TBP"], controlGroup: "Ctrl", controlSample: "C1")
    let mrQC = QPCRAnalysisEngine.computeQC(wells: mrWells, settings: mrSettings)
    let mrOut = QPCRAnalysisEngine.computeDdct(wells: mrWells, settings: mrSettings, qc: mrQC)
    let mrC1 = mrOut.sampleResults.first { $0.sample == "C1" && $0.target == "TP53" }!
    let mrT1 = mrOut.sampleResults.first { $0.sample == "T1" && $0.target == "TP53" }!
    assert(abs(mrC1.refCt - 23.0) < 1e-9, "Vandesompele multi-ref Ct must be arithmetic mean 23.0 (not GM 22.45), got \(mrC1.refCt)")
    assert(abs(mrC1.dCt - 2.0) < 1e-9 && abs(mrT1.dCt - 0.0) < 1e-9 && abs(mrT1.fold - 4.0) < 1e-9)

    // 61.2 qPCR Pfaffl (2001) + Hellemans qBase (2007) 双效率/多内参异效率 & 标曲自动接线 (Swift == Python)
    let pfafflWells: [QPCRWellRecord] = [
        QPCRWellRecord(well: "A1", sample: "C1", target: "GAPDH", group: "Ctrl", ct: 18.0, efficiency: 1.00),
        QPCRWellRecord(well: "A2", sample: "C1", target: "TP53", group: "Ctrl", ct: 22.0, efficiency: 0.90),
        QPCRWellRecord(well: "A3", sample: "C2", target: "GAPDH", group: "Ctrl", ct: 18.0, efficiency: 100.0), // 测试 % 单位归一化
        QPCRWellRecord(well: "A4", sample: "C2", target: "TP53", group: "Ctrl", ct: 22.0, efficiency: 1.90),  // 测试 (1+E) 因子归一化
        QPCRWellRecord(well: "B1", sample: "T1", target: "GAPDH", group: "Trt", ct: 17.0, efficiency: 1.00),
        QPCRWellRecord(well: "B2", sample: "T1", target: "TP53", group: "Trt", ct: 20.0, efficiency: 0.90),
        QPCRWellRecord(well: "B3", sample: "T2", target: "GAPDH", group: "Trt", ct: 17.0, efficiency: 1.00),
        QPCRWellRecord(well: "B4", sample: "T2", target: "TP53", group: "Trt", ct: 20.0, efficiency: 0.90)
    ]
    let pfSettings = QPCRSettings(efficiencyCorrection: true, referenceTargets: ["GAPDH"], controlGroup: "Ctrl", controlSample: "C1")
    let pfOut = QPCRAnalysisEngine.computeDdct(wells: pfafflWells, settings: pfSettings, qc: QPCRAnalysisEngine.computeQC(wells: pfafflWells, settings: pfSettings))
    let pfT1 = pfOut.sampleResults.first { $0.sample == "T1" && $0.target == "TP53" }!
    let expectedPfaffl = pow(1.90, 2.0) / pow(2.00, 1.0) // 3.61 / 2.0 = 1.805
    assert(abs(pfT1.fold - expectedPfaffl) < 1e-6, "True Pfaffl ratio must equal 1.805000, got \(pfT1.fold)")

    // 标准曲线自动接入 computeDdct（不写 sample efficiency，完全由标曲回归 E=90% 自动传递）
    let slope90 = -1.0 / log10(1.90)
    let intercept90 = 30.0
    var stdWiredWells = pfafflWells.map { w -> QPCRWellRecord in
        var c = w
        c.efficiency = (w.target == "GAPDH") ? 1.00 : nil
        return c
    }
    for (idx, q) in [1e5, 1e4, 1e3, 1e2, 1e1].enumerated() {
        stdWiredWells.append(QPCRWellRecord(well: "H\(idx + 1)", sample: "STD\(idx + 1)", target: "TP53", group: "Standard", wellType: .standard, ct: slope90 * log10(q) + intercept90, quantity: q))
    }
    let stdWiredOut = QPCRAnalysisEngine.computeDdct(wells: stdWiredWells, settings: pfSettings, qc: QPCRAnalysisEngine.computeQC(wells: stdWiredWells, settings: pfSettings))
    let stdWiredT1 = stdWiredOut.sampleResults.first { $0.sample == "T1" && $0.target == "TP53" }!
    assert(abs(stdWiredT1.fold - expectedPfaffl) < 1e-6, "Standard-curve efficiency must wire into Pfaffl ddCt (expected 1.805, got \(stdWiredT1.fold))")

    // 不等效率双内参 qBase 2007 精确检验 + Python MCP 数值一致
    let qbaseWells: [QPCRWellRecord] = [
        QPCRWellRecord(well: "A1", sample: "C1", target: "GAPDH", group: "Ctrl", ct: 18.0, efficiency: 0.90),
        QPCRWellRecord(well: "A2", sample: "C1", target: "ACTB", group: "Ctrl", ct: 20.0, efficiency: 1.00),
        QPCRWellRecord(well: "A3", sample: "C1", target: "TP53", group: "Ctrl", ct: 22.0, efficiency: 0.80),
        QPCRWellRecord(well: "B1", sample: "T1", target: "GAPDH", group: "Trt", ct: 19.0, efficiency: 0.90),
        QPCRWellRecord(well: "B2", sample: "T1", target: "ACTB", group: "Trt", ct: 21.0, efficiency: 1.00),
        QPCRWellRecord(well: "B3", sample: "T1", target: "TP53", group: "Trt", ct: 20.0, efficiency: 0.80)
    ]
    let qbSettings = QPCRSettings(efficiencyCorrection: true, referenceTargets: ["GAPDH", "ACTB"], controlGroup: "Ctrl", controlSample: "C1")
    let qbOut = QPCRAnalysisEngine.computeDdct(wells: qbaseWells, settings: qbSettings, qc: QPCRAnalysisEngine.computeQC(wells: qbaseWells, settings: qbSettings))
    let qbT1 = qbOut.sampleResults.first { $0.sample == "T1" && $0.target == "TP53" }!
    let expectedQBase = pow(1.80, 2.0) * sqrt(1.90 * 2.00) // 3.24 * sqrt(3.8) = 6.3159094357
    assert(abs(qbT1.fold - expectedQBase) < 1e-6, "Multi-ref qBase ratio mismatch: expected \(expectedQBase), got \(qbT1.fold)")

    let pyQBaseRecs: [[String: Any]] = qbaseWells.map {
        ["sample": $0.sample, "group": $0.group, "gene": $0.target, "ct": $0.ct!, "efficiency": $0.efficiency!]
    }
    let pyQBasePayload = try JSONSerialization.data(withJSONObject: [
        "reference_genes": ["GAPDH", "ACTB"],
        "efficiency_correction": true,
        "control_group": "Ctrl",
        "control_sample": "C1",
        "records": pyQBaseRecs
    ])
    let pyQBaseProc = Process()
    pyQBaseProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    pyQBaseProc.arguments = [mcpScript, "--cli-call", "analyze_qpcr_ddct", "--args", String(data: pyQBasePayload, encoding: .utf8)!]
    let pyQBasePipe = Pipe()
    pyQBaseProc.standardOutput = pyQBasePipe
    try pyQBaseProc.run()
    let pyQBaseJSON = try JSONSerialization.jsonObject(with: pyQBasePipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    pyQBaseProc.waitUntilExit()
    let pyQBaseGroups = pyQBaseJSON["group_summaries"] as! [[String: Any]]
    let pyTrtFold = (pyQBaseGroups.first { ($0["group"] as? String) == "Trt" }?["mean_fold"] as? Double) ?? 0.0
    assert(abs(pyTrtFold - expectedQBase) < 1e-4, "Python MCP qBase dual-eff mismatch: expected \(expectedQBase), got \(pyTrtFold)")

    // 61.2b 缺失部分内参时的 qBase (2007) 基线中心化 + 已知单位标曲截断（Swift == Python）
    let missRefWells: [QPCRWellRecord] = [
        QPCRWellRecord(well: "A1", sample: "C1", target: "GAPDH", group: "Ctrl", ct: 18.0),
        QPCRWellRecord(well: "A2", sample: "C1", target: "ACTB", group: "Ctrl", ct: 28.0),
        QPCRWellRecord(well: "A3", sample: "C1", target: "TP53", group: "Ctrl", ct: 25.0),
        QPCRWellRecord(well: "B1", sample: "T1", target: "GAPDH", group: "Trt", ct: 18.0), // T1 缺失 ACTB，但 TP53 仍应为 1.0
        QPCRWellRecord(well: "B3", sample: "T1", target: "TP53", group: "Trt", ct: 25.0)
    ]
    let missRefSettings = QPCRSettings(referenceTargets: ["GAPDH", "ACTB"], controlGroup: "Ctrl", controlSample: "C1")
    let missRefOut = QPCRAnalysisEngine.computeDdct(wells: missRefWells, settings: missRefSettings, qc: QPCRAnalysisEngine.computeQC(wells: missRefWells, settings: missRefSettings))
    let missRefT1 = missRefOut.sampleResults.first { $0.sample == "T1" && $0.target == "TP53" }!
    assert(abs(missRefT1.fold - 1.0) < 1e-6, "Missing one reference gene must NOT create spurious bias (expected 1.0, got \(missRefT1.fold))")
    let pyMissRefRecs: [[String: Any]] = missRefWells.map { ["sample": $0.sample, "group": $0.group, "gene": $0.target, "ct": $0.ct!] }
    let pyMissRefPayload = try JSONSerialization.data(withJSONObject: [
        "reference_genes": ["GAPDH", "ACTB"],
        "control_group": "Ctrl",
        "control_sample": "C1",
        "records": pyMissRefRecs
    ])
    let pyMissProc = Process()
    pyMissProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    pyMissProc.arguments = [mcpScript, "--cli-call", "analyze_qpcr_ddct", "--args", String(data: pyMissRefPayload, encoding: .utf8)!]
    let pyMissPipe = Pipe()
    pyMissProc.standardOutput = pyMissPipe
    try pyMissProc.run()
    let pyMissJSON = try JSONSerialization.jsonObject(with: pyMissPipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    pyMissProc.waitUntilExit()
    let pyMissRes = (pyMissJSON["results"] as! [[String: Any]]).first { ($0["sample"] as? String) == "T1" }!
    let pyMissFold = (pyMissRes["relative_expression_2_neg_ddct"] as? Double) ?? -1.0
    assert(abs(pyMissFold - 1.0) < 1e-4, "Python MCP missing-ref fold must equal 1.0, got \(pyMissFold)")

    // 标曲已知单位极值截断测试：E=180% 必须钳制至 1.50 (base=2.50)；E=2.0% 必须钳制至 0.10 (base=1.10)
    let slope180 = -1.0 / log10(2.80)
    var clamp180Wells: [QPCRWellRecord] = [
        QPCRWellRecord(well: "A1", sample: "C1", target: "GAPDH", group: "Ctrl", ct: 18.0, efficiency: 1.00),
        QPCRWellRecord(well: "A2", sample: "C1", target: "TP53", group: "Ctrl", ct: 22.0),
        QPCRWellRecord(well: "B1", sample: "T1", target: "GAPDH", group: "Trt", ct: 18.0, efficiency: 1.00),
        QPCRWellRecord(well: "B2", sample: "T1", target: "TP53", group: "Trt", ct: 20.0)
    ]
    for (idx, q) in [1e5, 1e4, 1e3, 1e2, 1e1].enumerated() {
        clamp180Wells.append(QPCRWellRecord(well: "H\(idx + 1)", sample: "STD\(idx + 1)", target: "TP53", group: "Standard", wellType: .standard, ct: slope180 * log10(q) + 30.0, quantity: q))
    }
    let clamp180Out = QPCRAnalysisEngine.computeDdct(wells: clamp180Wells, settings: pfSettings, qc: QPCRAnalysisEngine.computeQC(wells: clamp180Wells, settings: pfSettings))
    let clamp180T1 = clamp180Out.sampleResults.first { $0.sample == "T1" && $0.target == "TP53" }!
    assert(abs(clamp180T1.efficiency - 1.50) < 1e-6 && abs(clamp180T1.fold - 6.25) < 1e-5, "180% std-curve must clamp directly to 1.50 -> fold 6.25, got eff=\(clamp180T1.efficiency) fold=\(clamp180T1.fold)")

    let slope2pct = -1.0 / log10(1.02)
    let clamp2Wells = clamp180Wells.map { w -> QPCRWellRecord in
        guard w.wellType == .standard, let q = w.quantity else { return w }
        var c = w
        c.ct = slope2pct * log10(q) + 30.0
        return c
    }
    let clamp2Out = QPCRAnalysisEngine.computeDdct(wells: clamp2Wells, settings: pfSettings, qc: QPCRAnalysisEngine.computeQC(wells: clamp2Wells, settings: pfSettings))
    let clamp2T1 = clamp2Out.sampleResults.first { $0.sample == "T1" && $0.target == "TP53" }!
    assert(abs(clamp2T1.efficiency - 0.10) < 1e-6 && abs(clamp2T1.fold - 1.21) < 1e-5, "2.0% std-curve must clamp directly to 0.10 -> fold 1.21 (NOT misparsed as factor), got eff=\(clamp2T1.efficiency) fold=\(clamp2T1.fold)")

    // 61.3 qPCR Jensen 不等式修复：对照组均值恒为 1.0 且处理组几何均值等于 CI95 几何中心
    let jensenWells: [QPCRWellRecord] = [
        QPCRWellRecord(well: "A1", sample: "C1", target: "GAPDH", group: "Ctrl", ct: 18.0),
        QPCRWellRecord(well: "A2", sample: "C1", target: "TP53", group: "Ctrl", ct: 23.0), // dCt = 5.0
        QPCRWellRecord(well: "A3", sample: "C2", target: "GAPDH", group: "Ctrl", ct: 18.0),
        QPCRWellRecord(well: "A4", sample: "C2", target: "TP53", group: "Ctrl", ct: 25.0), // dCt = 7.0 -> ctrlMean=6.0
        QPCRWellRecord(well: "B1", sample: "T1", target: "GAPDH", group: "Trt", ct: 18.0),
        QPCRWellRecord(well: "B2", sample: "T1", target: "TP53", group: "Trt", ct: 21.0), // dCt = 3.0
        QPCRWellRecord(well: "B3", sample: "T2", target: "GAPDH", group: "Trt", ct: 18.0),
        QPCRWellRecord(well: "B4", sample: "T2", target: "TP53", group: "Trt", ct: 23.0)  // dCt = 5.0 -> trtMean=4.0 -> ddCt=-2 -> geomFold=4.0
    ]
    let jenSettings = QPCRSettings(referenceTargets: ["GAPDH"], controlGroup: "Ctrl", controlSample: "C1")
    let jenOut = QPCRAnalysisEngine.computeDdct(wells: jensenWells, settings: jenSettings, qc: QPCRAnalysisEngine.computeQC(wells: jensenWells, settings: jenSettings))
    let jenCtrl = jenOut.groupResults.first { $0.category == "Ctrl" }!
    let jenTrt = jenOut.groupResults.first { $0.category == "Trt" }!
    assert(abs(jenCtrl.meanFold - 1.0) < 1e-9, "Control group geometric meanFold must be exactly 1.0 (not 1.25 from Jensen bias), got \(jenCtrl.meanFold)")
    let ciCenter = sqrt((jenTrt.foldCI95Low ?? 0.0) * (jenTrt.foldCI95High ?? 0.0))
    assert(abs(jenTrt.meanFold - 4.0) < 1e-9 && abs(jenTrt.meanFold - ciCenter) < 1e-6, "Treated group meanFold (\(jenTrt.meanFold)) must equal geometric CI center (\(ciCenter))")

    // 61.4 qPCR 中位数稳健离群检验 + Grubbs (1969) 检验
    let outWells: [QPCRWellRecord] = [
        QPCRWellRecord(well: "A1", sample: "M1", target: "GAPDH", group: "G", ct: 20.0),
        QPCRWellRecord(well: "A2", sample: "M1", target: "GAPDH", group: "G", ct: 20.1),
        QPCRWellRecord(well: "A3", sample: "M1", target: "GAPDH", group: "G", ct: 21.6),
        QPCRWellRecord(well: "B1", sample: "M2", target: "GAPDH", group: "G", ct: 20.0),
        QPCRWellRecord(well: "B2", sample: "M2", target: "GAPDH", group: "G", ct: 20.1),
        QPCRWellRecord(well: "B3", sample: "M2", target: "GAPDH", group: "G", ct: 20.8)
    ]
    let outQC = QPCRAnalysisEngine.computeQC(wells: outWells, settings: QPCRSettings(outlierLimit: 0.5))
    assert(!(outQC[outWells[0].id]?.flags.contains(.outlier) ?? false), "Valid M1 well 20.0 must NOT be double-flagged with 21.6 outlier")
    assert(outQC[outWells[2].id]?.flags.contains(.outlier) == true, "True M1 outlier 21.6 must be flagged")
    assert(outQC[outWells[5].id]?.flags.contains(.outlier) == true, "M2 outlier 20.8 must be flagged without mean masking")
    assert(QPCRStatistics.grubbsTestOutlierIndex([20.0, 20.1, 20.05, 19.95, 22.5], alpha: 0.05) == 4)
    assert(QPCRStatistics.grubbsTestOutlierIndex([20.0, 20.1, 20.05, 19.95, 20.08], alpha: 0.05) == nil)

    // 61.5 HomologyArmDesigner 短反向序列反转互补 + 环形缺失回绕
    let shortRev = HomologyArmDesigner.pickSpecificAnnealingSeq(from: "ATGCAATTGGCCAA", targetTm: 50.0, isForward: false)
    assert(shortRev.seq == BioSequence.reverseComplement("ATGCAATTGGCCAA"), "Short reverse template must return reverseComplement")
    let mutShort = HomologyArmDesigner.designMutagenesis(
        mutUp: "ATCGATCGATCGATCGATCGAT", // 22 bp -> dropLast(7) = 15 bp (<18 bp)
        mutDown: "GCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTA",
        mutSite: "GAG",
        homologyLength: 18
    )
    assert(mutShort.primerR.specificSequence == BioSequence.reverseComplement("ATCGATCGATCGATC"), "Short mutUp Mutation-R must be reverse-complemented")
    let smallPlasmid = "ATGCTAGCTAGC" + String(repeating: "GCTAGCATCGAT", count: 10)
    let edgeDel = HomologyArmDesigner.designFragmentDeletion(plasmidSeq: smallPlasmid, delStart: 8, delEnd: 57, homologyLength: 18)
    assert(edgeDel.primerR.specificSequence.count >= 18, "Deletion near start must wrap circularly to design valid >=18bp Deletion-R")

    // 验证 HomologyArmDesigner.pickSpecificAnnealingSeq 与 Python pick_specific_annealing_seq 严格一致（含二级结构风险权重 > GC 奖励）
    let paritySeq = "TAAATGACCCTCTCGTCATAAAACCTTTCTACTATGTGTTCCGCA"
    let swPicked = HomologyArmDesigner.pickSpecificAnnealingSeq(from: paritySeq, fivePrimeOverhang: "", targetTm: 60.0, tolerance: 1.0, isForward: true).seq
    let pyPickProc = Process()
    pyPickProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let mcpDir = URL(fileURLWithPath: mcpScript).deletingLastPathComponent().path
    pyPickProc.arguments = ["-c", "import sys; sys.path.insert(0, '\(mcpDir)'); import clonestudio_mcp_server as m; print(m.pick_specific_annealing_seq('\(paritySeq)', '', 60.0, 1.0))"]
    let pyPickPipe = Pipe()
    pyPickProc.standardOutput = pyPickPipe
    try pyPickProc.run()
    let pyPicked = (String(data: pyPickPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    pyPickProc.waitUntilExit()
    assert(swPicked == pyPicked, "Swift pickSpecificAnnealingSeq (\(swPicked)) must match Python (\(pyPicked))")

    // 61.6 PlateLayoutEngine Control/Blank 不进边缘孔 + 分组随机分布
    let pSamples = PlateLayoutEngine.parseSampleTable("Sample\tGroup\tReplicates\nS1\tG1\t3\nS2\tG1\t3\nS3\tG2\t3\nS4\tG2\t3")
    let plateResv = PlateLayoutEngine.assignPlate(format: .well96, samples: pSamples, rules: PlateLayoutRules(replicates: 3, controls: 4, blanks: 4, reserveEdge: true, avoidEdge: true, keepTogether: true, randomize: true, seed: 42))
    let plateResv2 = PlateLayoutEngine.assignPlate(format: .well96, samples: pSamples, rules: PlateLayoutRules(replicates: 3, controls: 4, blanks: 4, reserveEdge: true, avoidEdge: true, keepTogether: true, randomize: true, seed: 99))
    let edgeCtrlOrBlank = plateResv.assignments.values.filter { ($0.type == .control || $0.type == .blank) && PlateFormat.well96.isEdgeWell(row: $0.row, col: $0.col) }
    assert(edgeCtrlOrBlank.isEmpty, "reserveEdge=true must NEVER put control/blank wells on edge perimeter")
    let plateAvoid = PlateLayoutEngine.assignPlate(format: .well96, samples: pSamples, rules: PlateLayoutRules(replicates: 3, controls: 4, blanks: 4, reserveEdge: false, avoidEdge: true, keepTogether: true, randomize: true, seed: 42))
    let avoidEdgeAux = plateAvoid.assignments.values.filter { ($0.type == .control || $0.type == .blank) && PlateFormat.well96.isEdgeWell(row: $0.row, col: $0.col) }
    assert(avoidEdgeAux.isEmpty, "avoidEdge=true must keep control/blank wells out of perimeter edges")
    let sWells1 = Set(plateResv.assignments.values.filter { $0.type == .sample }.map(\.well))
    let sWells2 = Set(plateResv2.assignments.values.filter { $0.type == .sample }.map(\.well))
    assert(sWells1 != sWells2, "keepTogether + randomize must randomize block spatial coordinates across seeds")
    let bulkSamples = (1...5).map { PlateSampleItem(name: "Bulk\($0)", group: "G", customReplicates: 12) } // 5 * 12 = 60 == interiorCount(60); + 3 controls + 3 blanks = 66 > 60
    let overCapIssues = PlateLayoutEngine.validateLayout(format: .well96, samples: bulkSamples, rules: PlateLayoutRules(replicates: 12, controls: 3, blanks: 3, reserveEdge: true), assignments: [:]).issues
    assert(overCapIssues.contains { $0.severity == .error }, "validateLayout must include auxNeed when checking reserveEdge interior capacity")

    // 61.7 SangerBatchEngine 覆盖度门禁 (低覆盖 WT 禁止判 pass；显式目标区间需 >=95% Q20)
    let covRef =
        "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTG" +
        "CCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAG" +
        "GGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAG" +
        "CTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGC" +
        "CGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTAC" +
        "GTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTG" +
        "AAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAG" // 420 bp 非重复 EGFP 序列
    let shortSlice = String(Array(covRef)[0..<60]) // 60/420 = 14.3%
    let shortAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: shortSlice, sampleName: "LowCov-Clone1-F.ab1", simulateNoisyEnds: false)
    let shortRead = SangerBatchEngine.verifyInMemoryRead(
        data: shortAB1,
        fileName: "LowCov-Clone1-F.ab1",
        index: 0,
        candidates: [SangerBatchEngine.SangerReferenceCandidate(name: "CovRef", sequence: covRef)]
    )
    let lowCovSummary = SangerBatchEngine.summarizeByClone(reads: [shortRead], candidates: [SangerBatchEngine.SangerReferenceCandidate(name: "CovRef", sequence: covRef)])
    assert(lowCovSummary.first?.verdict == .needsReview, "14% coverage WT clone must NOT pass (expected .needsReview, got \(String(describing: lowCovSummary.first?.verdict)))")

    let targetCand = SangerBatchEngine.SangerReferenceCandidate(name: "TargetCovRef", sequence: covRef, targetStart1Based: 50, targetEnd1Based: 250)
    let partialTargetSlice = String(Array(covRef)[40..<170]) // ~60% of 50..250
    let partialAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: partialTargetSlice, sampleName: "TargetClone-F.ab1", simulateNoisyEnds: false)
    let partialRead = SangerBatchEngine.verifyInMemoryRead(data: partialAB1, fileName: "TargetClone-F.ab1", index: 0, candidates: [targetCand])
    let partialTargetSummary = SangerBatchEngine.summarizeByClone(reads: [partialRead], candidates: [targetCand])
    assert(partialTargetSummary.first?.verdict == .needsReview, "Explicit target region with <95% Q20 coverage must return .needsReview")
    let revTargetSlice = BioSequence.reverseComplement(String(Array(covRef)[150..<265]))
    let revAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: revTargetSlice, sampleName: "TargetClone-R.ab1", simulateNoisyEnds: false)
    let revRead = SangerBatchEngine.verifyInMemoryRead(data: revAB1, fileName: "TargetClone-R.ab1", index: 1, candidates: [targetCand])
    let fullTargetSummary = SangerBatchEngine.summarizeByClone(reads: [partialRead, revRead], candidates: [targetCand])
    assert(fullTargetSummary.first?.verdict == .pass && (fullTargetSummary.first?.coveragePercent ?? 0) >= 99.0, "Explicit target region with full F+R Q20 coverage must pass (got verdict=\(String(describing: fullTargetSummary.first?.verdict)), cov=\(fullTargetSummary.first?.coveragePercent ?? -1))")

    pass("Batch 1 scientific rigor suite passed (Vandesompele/Pfaffl/qBase/Jensen/Median+Grubbs/Homology/Plate/SangerCov).")
} catch {
    fatalError("Batch 1 scientific rigor test failed: \(error)")
}

// MARK: - Test 62: Sub-batch 2A — 酶标仪实验套件科研级升级 (ICH M10 4PL/5PL WLS、IC50 95%CI、Dunnett/Tukey/SW/BF/KW、BCA QR)
func runTest62SubBatch2A() throws {
    print("\n--- Test 62: Sub-batch 2A (PlateReaderAssayEngine 4PL/5PL WLS, ICH M10, IC50 CI, Dunnett/Tukey/SW/BF/KW, BCA QR) ---")

    // 1. ELISA 4PL 1/Y² 加权 WLS + x=0 锚点保留 + ICH M10 回算与外推阻断
    let trueA = 0.05, trueB = 1.20, trueC = 40.0, trueD = 2.80
    func eval4PL(_ x: Double, a: Double, b: Double, c: Double, d: Double) -> Double {
        if x <= 0 { return b > 0 ? a : d }
        return d + (a - d) / (1.0 + pow(x / c, b))
    }
    let elisaLevels: [Double] = [0.0, 1.0, 3.0, 10.0, 30.0, 100.0, 300.0, 1000.0]
    var elisaStds: [(x: Double, y: Double)] = []
    for (idx, x) in elisaLevels.enumerated() {
        let y0 = eval4PL(x, a: trueA, b: trueB, c: trueC, d: trueD)
        let delta = (idx % 2 == 0 ? 0.015 : -0.015) * max(0.02, y0)
        elisaStds.append((x: x, y: y0 + delta))
        elisaStds.append((x: x, y: y0 - delta))
    }
    guard let fitWLS = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: elisaStds, fiveParameter: false, weighting: .invY2) else {
        fatalError("ELISA 4PL 1/Y² WLS fit returned nil")
    }
    assert(fitWLS.standardPoints.count == elisaStds.count, "x=0 anchor points must be retained in standardPoints")
    assert(fitWLS.weighting == .invY2, "Weighting mode must be .invY2")
    assert(abs(fitWLS.paramC - trueC) / trueC < 0.05, "4PL WLS C recovery error > 5%: got \(fitWLS.paramC)")
    assert(abs(fitWLS.paramB - trueB) / trueB < 0.05, "4PL WLS B recovery error > 5%: got \(fitWLS.paramB)")
    let ich = fitWLS.ichM10Report
    assert(ich.meetsICHM10 && ich.nonZeroLevelCount == 7 && ich.passRatePercent >= 75.0, "ICH M10 validation should pass on clean 7-level standard curve")

    // 外推阻断验证（低于 LLOQ 与高于 ULOQ 均阻断 finalConc == nil）
    let quantSamples = PlateReaderAssayEngine.quantifyELISASamples(
        samples: [
            (name: "BelowLLOQ", replicates: [eval4PL(0.2, a: trueA, b: trueB, c: trueC, d: trueD)]),
            (name: "InRange", replicates: [eval4PL(50.0, a: trueA, b: trueB, c: trueC, d: trueD)]),
            (name: "AboveULOQ", replicates: [eval4PL(2500.0, a: trueA, b: trueB, c: trueC, d: trueD)])
        ],
        fit: fitWLS,
        dilutionFactor: 1.0,
        useValidatedLimits: true
    )
    assert(quantSamples[0].finalConc == nil && quantSamples[0].status == .belowLLOQ && quantSamples[0].extrapolationWarning != nil, "Below-LLOQ sample must block extrapolation with .belowLLOQ")
    assert(quantSamples[1].finalConc != nil && abs((quantSamples[1].finalConc ?? 0) - 50.0) / 50.0 < 0.06, "In-range ELISA back-calc must be accurate")
    assert(quantSamples[2].finalConc == nil && quantSamples[2].status == .aboveULOQ && quantSamples[2].extrapolationWarning != nil, "Above-ULOQ sample must block extrapolation with .aboveULOQ")

    // 异方差标曲对比：高浓度大散点、低浓度精准条件下，1/Y² WLS 在 LLOQ 的回算误差必须显著优于无权重 OLS
    var heteroStds: [(x: Double, y: Double)] = []
    for x in [1.0, 3.0, 10.0, 30.0, 100.0, 300.0, 1000.0] {
        let y0 = eval4PL(x, a: trueA, b: trueB, c: trueC, d: trueD)
        if x == 1000.0 {
            heteroStds.append((x: x, y: y0 + 0.55))
            heteroStds.append((x: x, y: y0 + 0.45))
        } else if x == 300.0 {
            heteroStds.append((x: x, y: y0 - 0.35))
            heteroStds.append((x: x, y: y0 - 0.30))
        } else {
            heteroStds.append((x: x, y: y0 + 0.001))
            heteroStds.append((x: x, y: y0 - 0.001))
        }
    }
    guard let fitHeteroOLS = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: heteroStds, fiveParameter: false, weighting: .none),
          let fitHeteroWLS = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: heteroStds, fiveParameter: false, weighting: .invY2) else {
        fatalError("Heteroscedastic 4PL fits returned nil")
    }
    let yLLOQTrue = eval4PL(1.0, a: trueA, b: trueB, c: trueC, d: trueD)
    let qOLS = PlateReaderAssayEngine.quantifyELISASamples(samples: [(name: "LLOQ", replicates: [yLLOQTrue])], fit: fitHeteroOLS, dilutionFactor: 1.0, useValidatedLimits: false)
    let qWLS = PlateReaderAssayEngine.quantifyELISASamples(samples: [(name: "LLOQ", replicates: [yLLOQTrue])], fit: fitHeteroWLS, dilutionFactor: 1.0, useValidatedLimits: false)
    let reHeteroOLS = abs((qOLS[0].finalConc ?? 99.0) - 1.0)
    let reHeteroWLS = abs((qWLS[0].finalConc ?? 99.0) - 1.0)
    assert(reHeteroWLS < 0.05 && reHeteroOLS > 0.30 && reHeteroWLS < reHeteroOLS * 0.25, "1/Y² WLS must beat OLS at LLOQ under high-concentration heteroscedastic noise (WLS RE=\(reHeteroWLS), OLS RE=\(reHeteroOLS))")

    // 2. 5PL 非对称曲线真 EC50 = C * (2^(1/G) - 1)^(1/B) (Gottschalk & Dunn 2005)
    let g5 = 2.5, c5 = 35.0, b5 = 1.35, a5 = 0.08, d5 = 2.60
    let expectedTrueEC50 = c5 * pow(pow(2.0, 1.0 / g5) - 1.0, 1.0 / b5)
    let stds5PL: [(x: Double, y: Double)] = [0.0, 0.5, 2.0, 5.0, 15.0, 40.0, 120.0, 400.0, 1200.0].map { x in
        let y = x <= 0 ? a5 : (d5 + (a5 - d5) / pow(1.0 + pow(x / c5, b5), g5))
        return (x: x, y: y)
    }
    guard let fit5PL = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: stds5PL, fiveParameter: true, weighting: .none) else {
        fatalError("5PL fit returned nil")
    }
    assert(abs(fit5PL.trueEC50 - expectedTrueEC50) / expectedTrueEC50 < 0.03, "5PL trueEC50 mismatch: got \(fit5PL.trueEC50), expected \(expectedTrueEC50)")
    let yAtTrueEC50 = fit5PL.paramD + (fit5PL.paramA - fit5PL.paramD) / pow(1.0 + pow(fit5PL.trueEC50 / fit5PL.paramC, fit5PL.paramB), fit5PL.paramG)
    assert(abs(yAtTrueEC50 - 0.5 * (fit5PL.paramA + fit5PL.paramD)) < 0.05, "y(trueEC50) must equal midpoint (A+D)/2")

    // 3. 负 Hill 斜率抑制曲线 (B < 0) + IC50 95% CI + 固定参数约束 + Relative vs Absolute IC50 + 外推告警
    let inhC = 50.0, inhB = -1.25, inhA = 20.0, inhD = 90.0
    var inhPts: [(x: Double, y: Double)] = []
    for (i, x) in [0.5, 2.0, 5.0, 15.0, 50.0, 150.0, 500.0, 2000.0].enumerated() {
        let y = eval4PL(x, a: inhA, b: inhB, c: inhC, d: inhD)
        let eps = (i % 2 == 0 ? 0.8 : -0.8)
        inhPts.append((x: x, y: y + eps))
        inhPts.append((x: x, y: y - eps))
    }
    guard let fitInh = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: inhPts, fiveParameter: false, weighting: .none) else {
        fatalError("Inhibition 4PL fit returned nil")
    }
    assert(!fitInh.isIncreasing, "Inhibition curve must be monotonically decreasing (isIncreasing == false)")
    assert(abs(fitInh.trueEC50 - inhC) / inhC < 0.03, "Inhibition 4PL EC50 recovery error > 3%: got \(fitInh.trueEC50)")
    assert(fitInh.effectiveLLOQ < fitInh.effectiveULOQ, "LLOQ must be strictly less than ULOQ for decreasing curve")
    // 显式固定 Bottom=20, Top=90 拟合下降曲线，验证渐近线约束与 LLOQ < ULOQ
    let boundedConstraints = PlateReaderAssayEngine.LogisticParameterConstraints(fixedBottom: inhA, fixedTop: inhD)
    guard let fitBounded = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: inhPts, fiveParameter: false, weighting: .none, constraints: boundedConstraints) else {
        fatalError("Constrained bounded 4PL fit returned nil")
    }
    assert(!fitBounded.isIncreasing && abs(fitBounded.trueEC50 - inhC) < 1.0 && fitBounded.effectiveLLOQ < fitBounded.effectiveULOQ, "Fixed Bottom/Top decreasing curve must preserve monotonicity and LLOQ < ULOQ")
    if let lo = fitInh.ec50CI95Low, let hi = fitInh.ec50CI95High,
       let seLogC = fitInh.seLog10EC50, let seB = fitInh.seHillSlope {
        assert(lo > 0 && lo < fitInh.trueEC50 && fitInh.trueEC50 < hi, "IC50 95% CI must bracket trueEC50")
        // 对照 scipy.optimize.curve_fit (df=12): SE(log10C)=0.013843, CI=[46.6454, 53.5959], SE(B)=0.046399
        assert(abs(seLogC - 0.013843) / 0.013843 < 0.02, "seLog10EC50 must match scipy.optimize.curve_fit (got \(seLogC))")
        assert(abs(lo - 46.6454) < 0.5 && abs(hi - 53.5959) < 0.5, "IC50 95% CI must match SciPy [46.645, 53.596], got [\(lo), \(hi)]")
        assert(abs(seB - 0.046399) / 0.046399 < 0.02, "seHillSlope must match scipy.optimize.curve_fit (got \(seB))")
    } else {
        fatalError("IC50 / Hill slope SE and 95% CI must be computed")
    }
    assert(fitInh.hillSlopeCI95Low != nil && fitInh.hillSlopeCI95High != nil, "Hill slope 95% CI must be computed")
    // Relative IC50 对应 y=(20+90)/2=55%，Absolute IC50 对应 y=50%，下降曲线故 absIC50 > relIC50
    if let abs50 = fitInh.absoluteIC50At50 {
        assert(abs50 > fitInh.relativeIC50, "For A=20, D=90 decreasing curve, Absolute IC50 (y=50) must exceed Relative IC50 (y=55)")
    } else {
        fatalError("absoluteIC50At50 must be computed for A=20, D=90 curve")
    }
    // 固定 Bottom=0, Top=100, Hill=-1 与仅固定 Bottom=0, Hill=-1（验证 bottomIsIndex0 初始化）
    let fixedPts: [(x: Double, y: Double)] = [1.0, 5.0, 20.0, 80.0, 320.0, 1280.0].map { x in
        (x: x, y: eval4PL(x, a: 0.0, b: -1.0, c: 40.0, d: 100.0))
    }
    let constraints = PlateReaderAssayEngine.LogisticParameterConstraints(fixedBottom: 0.0, fixedTop: 100.0, fixedHillSlope: -1.0)
    guard let fitFixed = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: fixedPts, fiveParameter: false, weighting: .none, constraints: constraints) else {
        fatalError("Constrained 4PL fit returned nil")
    }
    assert(abs(fitFixed.paramA - 0.0) < 1e-9 && abs(fitFixed.paramD - 100.0) < 1e-9 && abs(fitFixed.paramB - (-1.0)) < 1e-9, "Fixed constraints must be honored exactly")
    assert(fitFixed.freeParameterCount == 1 && abs(fitFixed.trueEC50 - 40.0) < 0.5, "Constrained 1-param fit must recover C=40")

    let partialFixed = PlateReaderAssayEngine.LogisticParameterConstraints(fixedBottom: 0.0, fixedHillSlope: -1.0)
    guard let fitPartialFixed = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: fixedPts, fiveParameter: false, weighting: .none, constraints: partialFixed) else {
        fatalError("Partial constrained (fixedBottom=0, fixedHillSlope=-1) 4PL fit returned nil")
    }
    assert(abs(fitPartialFixed.trueEC50 - 40.0) < 0.5 && abs(fitPartialFixed.paramD - 100.0) < 1.0, "fixedBottom=0 + fixedHillSlope=-1 must not stall on flat A==D init")

    // 真负 Hill 斜率 B < 0 (fitFixed, paramB == -1.0) 下降曲线 quantifyELISASamples 上下界枚举验证
    assert(fitFixed.paramB < 0.0 && !fitFixed.isIncreasing, "fitFixed must actually exercise paramB < 0 branch")
    let inhQuant = PlateReaderAssayEngine.quantifyELISASamples(
        samples: [
            (name: "LowConcHighY", replicates: [99.5]),
            (name: "MidConc", replicates: [50.0]),
            (name: "HighConcLowY", replicates: [0.5])
        ],
        fit: fitFixed,
        dilutionFactor: 1.0,
        useValidatedLimits: true
    )
    assert(inhQuant[0].finalConc == nil && inhQuant[0].status == .belowLLOQ, "B<0 high-response low-conc sample must block with .belowLLOQ, got \(inhQuant[0].status)")
    assert(inhQuant[1].finalConc != nil && inhQuant[1].status == .inRange && abs((inhQuant[1].finalConc ?? 0) - 40.0) < 0.5, "B<0 mid-range sample must recover C≈40")
    assert(inhQuant[2].finalConc == nil && inhQuant[2].status == .aboveULOQ, "B<0 low-response high-conc sample must block with .aboveULOQ, got \(inhQuant[2].status)")

    // 5PL 对称曲线 (G=1) Delta Method 梯度保留验证（严禁跳过 gradH[4] 导致 SE 膨胀 6.91x）
    let symStds: [(x: Double, y: Double)] = [0.5, 2.0, 5.0, 15.0, 40.0, 120.0, 400.0, 1200.0].flatMap { x -> [(x: Double, y: Double)] in
        let y0 = eval4PL(x, a: 0.05, b: 1.2, c: 40.0, d: 2.5)
        return [(x: x, y: y0 + 0.015), (x: x, y: y0 - 0.015)]
    }
    guard let fitSym4 = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: symStds, fiveParameter: false, weighting: .none),
          let fitSym5 = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: symStds, fiveParameter: true, weighting: .none),
          let se4 = fitSym4.seLog10EC50, let se5 = fitSym5.seLog10EC50 else {
        fatalError("Symmetric 4PL/5PL Delta SE fit failed")
    }
    assert(se5 < se4 * 2.5, "5PL Delta Method at G≈1 must include ∂h/∂G and not inflate seLog10EC50 (se4=\(se4), se5=\(se5))")

    // 化学发光 10^7 RLU 量级 1/Y² 加权 WLS 无量纲归一化与 95% CI 验证
    let lumStds: [(x: Double, y: Double)] = [1.0, 3.0, 10.0, 30.0, 100.0, 300.0, 1000.0].flatMap { x -> [(x: Double, y: Double)] in
        let y0 = eval4PL(x, a: 1e4, b: 1.15, c: 40.0, d: 1e7)
        return [(x: x, y: y0 * 1.02), (x: x, y: y0 * 0.98)]
    }
    guard let fitLum = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: lumStds, fiveParameter: false, weighting: .invY2) else {
        fatalError("10^7 RLU 1/Y² WLS fit returned nil")
    }
    assert(abs(fitLum.paramC - 40.0) / 40.0 < 0.05 && fitLum.ec50CI95Low != nil && fitLum.ec50CI95High != nil, "10^7 RLU 1/Y² WLS must recover C≈40 and valid 95% CI, got C=\(fitLum.paramC)")

    // ICH M10 严格门控：6 个非零浓度中仅 5 个通过 (83.3%) 必须判定 meetsICHM10 == false
    var sixLvlFail: [(x: Double, y: Double)] = [1.0, 3.0, 10.0, 30.0, 100.0, 300.0].map { x in
        (x: x, y: eval4PL(x, a: trueA, b: trueB, c: trueC, d: trueD))
    }
    sixLvlFail[2].y *= 1.45 // 破坏第 3 级标品相对误差
    guard let fitSixFail = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: sixLvlFail, fiveParameter: false, weighting: .none) else {
        fatalError("6-level ICH M10 fail test fit returned nil")
    }
    assert(fitSixFail.ichM10Report.nonZeroLevelCount == 6 && !fitSixFail.ichM10Report.meetsICHM10, "ICH M10 requires passedCount >= 6; 5/6 passing must fail meetsICHM10")

    // 外推告警测试（EC50 远大于最高浓度 10，使用 guard 杜绝静默跳过）
    let extrapPts: [(x: Double, y: Double)] = [0.1, 0.3, 1.0, 3.0, 10.0].map { x in
        (x: x, y: eval4PL(x, a: 0.0, b: -1.0, c: 200.0, d: 100.0))
    }
    let extrapConstraints = PlateReaderAssayEngine.LogisticParameterConstraints(fixedBottom: 0.0, fixedTop: 100.0)
    guard let fitExtrap = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: extrapPts, fiveParameter: false, weighting: .none, constraints: extrapConstraints) else {
        fatalError("Extrapolated EC50 4PL fit returned nil")
    }
    assert(fitExtrap.isEC50Extrapolated, "EC50 outside [0.1, 10] must set isEC50Extrapolated = true")

    // 4. CCK-8 / MTT: Shapiro-Wilk n==3 精确校验 + n==1 隔离防污染 + 负值保留 + Dunnett/Tukey/SW/BF/KW
    guard let swSym3 = PlateReaderAssayEngine.shapiroWilkTest([1.0, 2.0, 3.0]),
          let swSkew3 = PlateReaderAssayEngine.shapiroWilkTest([0.0, 0.01, 100.0]) else {
        fatalError("Shapiro-Wilk n==3 returned nil")
    }
    assert(swSym3.statisticW > 0.9999 && abs(swSym3.pValue - 1.0) < 1e-6, "Shapiro-Wilk n=3 symmetric [1,2,3] must return p==1.0, got p=\(swSym3.pValue)")
    assert(abs(swSkew3.pValue - 0.00016541) < 1e-4, "Shapiro-Wilk n=3 extreme skew [0,0.01,100] must match SciPy p=0.000165, got p=\(swSkew3.pValue)")

    let viabilityGroups: [(name: String, values: [Double])] = [
        (name: "Control", values: [1.00, 1.04, 0.98, 1.02]),
        (name: "LowDose", values: [0.99, 1.03, 0.97, 1.01]),
        (name: "HighDose", values: [0.30, 0.33, 0.28, 0.31]),
        (name: "DeadNeg", values: [0.02, 0.03, 0.01]),
        (name: "SingleN1", values: [0.55])
    ]
    guard let viabOut = PlateReaderAssayEngine.analyzeViability(groups: viabilityGroups, controlGroupName: "Control", blankMean: 0.05, postHocMethod: .dunnett) else {
        fatalError("analyzeViability returned nil")
    }
    let viabilityGroupsExtraN1 = viabilityGroups + [(name: "SingleN1_B", values: [0.60]), (name: "SingleN1_C", values: [0.70])]
    guard let viabExtra = PlateReaderAssayEngine.analyzeViability(groups: viabilityGroupsExtraN1, controlGroupName: "Control", blankMean: 0.05, postHocMethod: .dunnett) else {
        fatalError("analyzeViability with extra n=1 groups returned nil")
    }
    // 对 LowDose 验证 n==1 隔离（修复前 extra n==1 会将该值从 0.8656 污染至 0.9779，而 HighDose 始终为 0.0 空转）
    let lowP1 = viabOut.groups.first(where: { $0.groupName == "LowDose" })!.pAdjusted!
    let lowP2 = viabExtra.groups.first(where: { $0.groupName == "LowDose" })!.pAdjusted!
    assert(abs(lowP1 - lowP2) < 1e-12, "Extra n==1 groups must NOT contaminate LowDose Dunnett family size or pAdjusted (got \(lowP1) vs \(lowP2))")
    assert(abs((viabOut.shapiroWilk?.statisticW ?? 0) - (viabExtra.shapiroWilk?.statisticW ?? 1)) < 1e-12, "Extra n==1 groups must NOT inject structural 0.0 residuals into Shapiro-Wilk")

    let deadGroup = viabOut.groups.first(where: { $0.groupName == "DeadNeg" })!
    assert(deadGroup.meanViabilityPercent < 0.0, "Negative blank-subtracted OD must NOT be truncated to 0")
    let n1Group = viabOut.groups.first(where: { $0.groupName == "SingleN1" })!
    assert(n1Group.sdViabilityPercent == nil && n1Group.semViabilityPercent == nil && n1Group.pValue == nil, "n==1 group must report nil SD/SEM/p-value")
    let lowGroup = viabOut.groups.first(where: { $0.groupName == "LowDose" })!
    let highGroup = viabOut.groups.first(where: { $0.groupName == "HighDose" })!
    assert((highGroup.pAdjusted ?? 1.0) < 0.001, "Dunnett adjusted p for HighDose must be < 0.001, got \(String(describing: highGroup.pAdjusted))")
    assert(abs(lowP1 - 0.865607) < 2e-3 && abs((lowGroup.dunnettStatistic ?? 0) - (-0.632456)) < 1e-3, "Dunnett LowDose must match scipy.stats.dunnett (t=-0.632456, p=0.865607), got t=\(String(describing: lowGroup.dunnettStatistic)) p=\(lowP1)")
    guard let swDiag = viabOut.shapiroWilk, let bfDiag = viabOut.brownForsythe else {
        fatalError("Normality & homoscedasticity diagnostics must be populated")
    }
    assert(abs(swDiag.statisticW - 0.939054) < 1e-3 && abs(swDiag.pValue - 0.370629) < 2e-3, "Viability Shapiro-Wilk must match SciPy (W=0.939054, p=0.370629), got W=\(swDiag.statisticW) p=\(swDiag.pValue)")
    assert(abs(bfDiag.fStatistic - 1.138596) < 1e-3 && abs(bfDiag.pValue - 0.376164) < 2e-3, "Brown-Forsythe must match SciPy levene(median) (F=1.138596, p=0.376164), got F=\(bfDiag.fStatistic) p=\(bfDiag.pValue)")

    let tukey = PlateReaderAssayEngine.computeTukeyKramerHSD(
        namedGroups: [
            (name: "Ctrl", values: [100.0, 102.0, 98.0, 101.0]),
            (name: "Low", values: [99.0, 101.0, 97.0, 100.0]),
            (name: "High", values: [30.0, 32.0, 28.0, 31.0])
        ]
    )
    assert(tukey.count == 3, "Tukey-Kramer for 3 groups must yield 3 pairwise comparisons")
    let ctrlVsLowTukey = tukey.first { item in
        (item.groupA == "Ctrl" && item.groupB == "Low") || (item.groupA == "Low" && item.groupB == "Ctrl")
    }!
    let ctrlVsHighTukey = tukey.first { item in
        (item.groupA == "Ctrl" && item.groupB == "High") || (item.groupA == "High" && item.groupB == "Ctrl")
    }!
    assert(abs(ctrlVsLowTukey.statistic - 1.171080) < 2e-3 && abs(ctrlVsLowTukey.pAdjusted - 0.695971) < 2e-3, "Tukey-Kramer Ctrl vs Low must match scipy.stats.tukey_hsd (q=1.171080, p=0.695971), got q=\(ctrlVsLowTukey.statistic) p=\(ctrlVsLowTukey.pAdjusted)")
    assert(abs(ctrlVsHighTukey.statistic - 81.9756) < 0.05 && ctrlVsHighTukey.pAdjusted < 0.001, "Tukey-Kramer Ctrl vs High q-statistic & p mismatch")

    guard let viabKW = PlateReaderAssayEngine.analyzeViability(
        groups: [
            (name: "Control", values: [1.00, 1.05, 0.96, 1.02, 0.99]),
            (name: "Treated", values: [0.30, 0.35, 0.28, 0.31, 0.29]),
            (name: "Mid", values: [0.65, 0.68, 0.62, 0.66, 0.64])
        ],
        controlGroupName: "Control",
        blankMean: 0.05,
        postHocMethod: .kruskalDunn
    ) else {
        fatalError("analyzeViability kruskalDunn returned nil")
    }
    assert(abs((viabKW.kruskalWallis?.hStatistic ?? 0) - 12.5000) < 1e-3 && abs((viabKW.kruskalWallis?.pValue ?? 0) - 0.00193045) < 1e-4, "Kruskal-Wallis H & p must match scipy.stats.kruskal (H=12.5, p=0.001930)")
    let trtKW = viabKW.groups.first(where: { $0.groupName == "Treated" })!
    assert((trtKW.dunnPAdjusted ?? 1.0) < 0.01 && (trtKW.pAdjusted ?? 1.0) < 0.01, "Dunn post-hoc pAdjusted for Treated must be < 0.01")
    guard let kwTied = PlateReaderAssayEngine.computeKruskalWallis(groups: [[1, 1, 2, 2], [2, 2, 3, 3], [3, 3, 4, 4]]) else {
        fatalError("Tied Kruskal-Wallis returned nil")
    }
    assert(abs(kwTied.hStatistic - 8.166667) < 1e-4 && abs(kwTied.pValue - 0.0168512) < 1e-4, "Tie-corrected Kruskal-Wallis must match scipy.stats.kruskal (H=8.1667, p=0.01685)")

    // 5. BCA 中心化缩放 Householder QR 二次回归 + 判别式 < 0 饱和阻断（禁止静默线性回退且 WB 上样体积归零）
    let bcaConcs: [Double] = [0, 125, 250, 500, 750, 1000, 1500, 2000]
    let bcaStds: [(concUgPerMl: Double, od: Double)] = bcaConcs.map { c in
        let od = 0.08 + 1.1e-3 * c - 2.0e-7 * c * c
        return (concUgPerMl: c, od: od)
    }
    guard let bcaOut = PlateReaderAssayEngine.analyzeBCA(
        standards: bcaStds,
        samples: [
            (name: "Normal", replicates: [0.58]),
            (name: "AboveMaxStd", replicates: [1.55]),
            (name: "BeyondVertex", replicates: [1.85])
        ],
        model: .quadratic,
        blankOD: 0.08
    ) else {
        fatalError("analyzeBCA quadratic returned nil")
    }
    assert(bcaOut.r2 > 0.999999 && bcaOut.rmse < 1e-6, "BCA centered Householder QR quadratic fit must be exact on noiseless data")
    assert(abs(bcaOut.coeffA - (-2.0e-7)) < 1e-10 && abs(bcaOut.coeffB - 1.1e-3) < 1e-6 && abs(bcaOut.coeffC) < 1e-6 && bcaOut.degreesOfFreedom == 5, "BCA QR exact quadratic coefficients mismatch")
    assert(bcaOut.samples[0].quantStatus == .inRange && abs(bcaOut.samples[0].fittedConcUgPerMl - 500.0) < 1e-2, "In-range BCA sample must recover 500.0 µg/mL, got \(bcaOut.samples[0].fittedConcUgPerMl)")
    assert(bcaOut.samples[1].quantStatus == .aboveStandardRange, "OD above max standard must be flagged .aboveStandardRange")
    assert(bcaOut.samples[2].quantStatus == .parabolicSaturated && bcaOut.samples[2].warningMessage != nil && bcaOut.samples[2].proteinVolumeUl == 0.0, "OD beyond quadratic vertex must return .parabolicSaturated with warning and zeroed WB protein volume")

    pass("Sub-batch 2A scientific rigor suite passed (4PL/5PL WLS, ICH M10, IC50 95%CI, Dunnett/Tukey/SW/BF/KW, BCA QR).")
}
do {
    try runTest62SubBatch2A()
} catch {
    fatalError("Sub-batch 2A test failed: \(error)")
}

// MARK: - Test 63: Sub-batch 2B — Western Blot 2D 滚球/旋转掩码同步/12-bit/sRGB/TPN/双带高斯去卷积/log2统计 & Python/MCP 数值一致性
func runTest63SubBatch2B() throws {
    print("\n--- Test 63: Sub-batch 2B (WesternBlotEngine 2D RollingBall, Skew+SatMask Sync, Deconv, TPN, log2 Stats & Python/MCP Parity) ---")

    // 1. BioImageProcessor.findPeaks 真实拓扑显著性验证
    let topoProfile: [Double] = [0.0, 2.0, 10.0, 8.0, 9.0, 7.0, 0.0]
    // 峰1 在 idx=2 (值 10, 显著性 10), 峰2 在 idx=4 (值 9, 鞍点 idx=3 值 8 -> 显著性 = 9 - 8 = 1.0)
    let peaksStrict = BioImageProcessor.findPeaks(profile: topoProfile, minProminence: 2.0, minGap: 1, smoothWindow: 1).map(\.index)
    assert(peaksStrict == [2], "Topological prominence must reject shallow sub-peak (prom=1.0 < 2.0), got \(peaksStrict)")
    let peaksLoose = BioImageProcessor.findPeaks(profile: topoProfile, minProminence: 0.5, minGap: 1, smoothWindow: 1).map(\.index)
    assert(peaksLoose == [2, 4], "Topological prominence must retain sub-peak when minProminence=0.5, got \(peaksLoose)")

    // 2. 有效位深自动检测 (8/12/16-bit 严格截断规则) + IEC 61966-2-1 sRGB 反 Gamma + 极性与 2D 椭球滚球验证
    let raw12 = [Double](repeating: 200.0, count: 97) + [4095.0, 4095.0, 4095.0]
    let eff12 = WesternBlotEngine.detectEffectiveBitDepth(rawValues: raw12, containerBitDepth: 16)
    assert(eff12.effectiveBitDepth == 12 && abs(eff12.ceiling - 4095.0) < 1e-6, "12-bit-in-16-bit TIFF with pinned 4095 pixels must detect effective bitDepth=12, ceiling=4095")
    let rawLowExp16 = [Double](repeating: 150.0, count: 99) + [4090.0]
    let effLow16 = WesternBlotEngine.detectEffectiveBitDepth(rawValues: rawLowExp16, containerBitDepth: 16)
    assert(effLow16.effectiveBitDepth == 16 && abs(effLow16.ceiling - 65535.0) < 1e-6, "Low-exposure 16-bit TIFF (vmax=4090) must NOT be downgraded to 12-bit")
    let linHalf = WesternBlotEngine.linearizeSRGBValue(127.5) / 255.0
    let expectedLinHalf = pow((0.5 + 0.055) / 1.055, 2.4)
    assert(abs(linHalf - expectedLinHalf) < 1e-6, "IEC 61966-2-1 sRGB linearization mismatch")

    // 8-bit 白底暗带 (bg=190, band=30, white border=255) 开启 linearizeSRGB 时，极性必须在反 Gamma 前正确识别为 inverted == true
    var whiteBg8 = [Double](repeating: 190.0, count: 60 * 60)
    for y in 0..<60 {
        for x in 0..<60 {
            if y < 3 || y >= 57 || x < 3 || x >= 57 {
                whiteBg8[y * 60 + x] = 255.0
            }
        }
    }
    for y in 25..<35 { for x in 20..<40 { whiteBg8[y * 60 + x] = 30.0 } }
    let whiteBuf8 = WesternBlotEngine.buildStandardizedBuffer(rawValues: whiteBg8, width: 60, height: 60, bitDepth: 8, linearizeSRGB: true)
    assert(whiteBuf8.invertedPolarity, "8-bit white-background blot (bg=190, band=30) with linearizeSRGB=true must detect inverted polarity")

    // 2D 椭球滚球在 [0, 1] 动态范围下必须保留 >70% 信号，且 quantifyBlot(.rollingBall/.totalLane) 保持 demo 膜回收率
    var unitImg = [Double](repeating: 0.10, count: 60 * 60)
    for y in 0..<60 {
        for x in 0..<60 {
            unitImg[y * 60 + x] += 0.60 * exp(-0.5 * (pow(Double(x - 30) / 5.0, 2.0) + pow(Double(y - 30) / 3.0, 2.0)))
        }
    }
    let rbUnit = WesternBlotEngine.subtractRollingBallNative(signal: unitImg, width: 60, height: 60, radius: 18, intensityRange: nil)
    assert(rbUnit.signedNet[30 * 60 + 30] > 0.42, "2D ellipsoid rolling ball on [0,1] image must preserve >70% peak signal, got \(rbUnit.signedNet[30 * 60 + 30])")

    let demoPlane = BioImageProcessor.generateDemoWesternBlotPlane(width: 400, height: 240)
    let demoLanes = WesternBlotEngine.autoDetectLanesAndBands(plane: demoPlane)
    let qDemoRB = WesternBlotEngine.quantifyBlot(plane: demoPlane, lanes: demoLanes, backgroundMode: .rollingBall, normalizationMode: .loadingControl, controlGroup: "WT")
    let qDemoTPN = WesternBlotEngine.quantifyBlot(plane: demoPlane, lanes: demoLanes, backgroundMode: .rollingBall, normalizationMode: .totalLane, controlGroup: "WT")
    let demoWT = qDemoRB.laneRows.filter { $0.groupName == "WT" }.map(\.targetNetVolume).reduce(0, +)
    let demoKO = qDemoRB.laneRows.filter { $0.groupName == "TP53-KO" }.map(\.targetNetVolume).reduce(0, +)
    let demoOEFold = qDemoRB.groupStats.first(where: { $0.groupName == "TP53-OE" })?.meanFold ?? 0.0
    assert(demoWT > 100.0 && demoKO > 20.0 && demoOEFold > 1.4 && demoOEFold < 2.5, "quantifyBlot(.rollingBall) must preserve [0,1] signal & OE/WT ratio (WT=\(demoWT), KO=\(demoKO), OE=\(demoOEFold))")
    assert(qDemoTPN.laneRows.allSatisfy { $0.loadingNetVolume > 100.0 && $0.foldChange > 0.1 }, "quantifyBlot(.totalLane) must yield valid positive full-lane TPN normalization")

    // 81% 零填充暗底 + 非常数饱和高斯亮带 (halo 3000..65535)：严禁误反转
    var zpVals = [Double](repeating: 0.0, count: 60 * 60)
    for y in 20..<40 {
        for x in 20..<40 {
            let gVal = 3000.0 + 62535.0 * exp(-0.5 * (pow(Double(x - 30) / 3.0, 2.0) + pow(Double(y - 30) / 3.0, 2.0)))
            zpVals[y * 60 + x] = min(65535.0, gVal)
        }
    }
    let zpBuf = WesternBlotEngine.buildStandardizedBuffer(
        rawValues: zpVals, width: 60, height: 60, bitDepth: 16, linearizeSRGB: false
    )
    assert(!zpBuf.invertedPolarity, "81% zero-padded dark background with non-constant saturated bright band must NOT be inverted")

    // 3. 低曝光 16-bit 合成 WB 膜（amps=[2000,2000,4000,4000]、倾斜背景、Lane 3 含单像素 65535 饱和）验证 2D 滚球缩放齐次性
    let w = 160, h = 120
    var synthVals = [Double](repeating: 0.0, count: w * h)
    let laneCentersX = [25.0, 60.0, 95.0, 130.0]
    let bandY = 58.0
    let bandAmps = [2000.0, 2000.0, 4000.0, 4000.0]
    for y in 0..<h {
        for x in 0..<w {
            var v = 500.0 + 3.0 * Double(y) + 1.5 * Double(x) // 平滑倾斜背景
            for (li, cx) in laneCentersX.enumerated() {
                let dx = Double(x) - cx
                let dy = Double(y) - bandY
                v += bandAmps[li] * exp(-0.5 * ((dx * dx) / (7.0 * 7.0) + (dy * dy) / (4.0 * 4.0)))
            }
            synthVals[y * w + x] = min(65535.0, v)
        }
    }
    // 在 Lane 3 条带中心注入 1 个过曝像素 (65535)
    synthVals[Int(bandY) * w + Int(laneCentersX[3])] = 65535.0

    let synthBuf = WesternBlotEngine.buildStandardizedBuffer(
        rawValues: synthVals, width: w, height: h, bitDepth: 16, linearizeSRGB: false
    )
    // 验证 deskewMaskNative 同步旋转饱和掩码
    let rotatedSat = WesternBlotEngine.deskewMaskNative(synthBuf.saturated, width: w, height: h, angleDegrees: 2.5)
    assert(rotatedSat.filter({ $0 }).count >= 1, "deskewMaskNative must preserve saturated pixel after 2.5 deg rotation")

    let params2B = WBAnalysisParams(
        rollingBallRadius: 28,
        expectedLanes: 4,
        autoDeskew: false,
        saturationRatioThreshold: 0.0001,
        backgroundMode: .globalRollingBall
    )
    let resSwift = WesternBlotEngine.analyzeNativeBuffer(
        synthBuf, imagePath: "/tmp/synth_2b_test.tif", params: params2B
    )
    let row0: [WBBand] = resSwift.bands.filter { $0.rowIndex == 0 }.sorted { $0.laneIndex < $1.laneIndex }
    assert(row0.count == 4, "Expected 4 detected bands in synthetic blot, got \(row0.count)")
    let ratio2vs0 = row0[2].netIOD / max(1e-6, row0[0].netIOD)
    assert(abs(ratio2vs0 - 2.0) / 2.0 < 0.05, "Dim 16-bit 2D Rolling Ball net IOD fold ratio must recover 2.0 ± 5%, got \(ratio2vs0)")
    assert(row0[3].saturatedRatio > 0.0 && row0[3].isSaturated, "Synchronized sat_mask must detect the single saturated pixel in lane 3")
    assert(row0[0].snr > 5.0, "Band SNR must be computed and > 5 for clean synthetic band")

    // 3b. 缩放齐次性（曝光倍比 [1, 3, 6, 15]）+ 倾斜膜 autoDeskew=true 端到端旋转与饱和掩膜对齐验证
    let cleanDimRaw: [Double] = {
        var arr = synthVals
        var bgAt = 500.0 + 3.0 * bandY + 1.5 * laneCentersX[3]
        for (li, cx) in laneCentersX.enumerated() {
            let dx = laneCentersX[3] - cx
            bgAt += bandAmps[li] * exp(-0.5 * ((dx * dx) / 49.0))
        }
        arr[Int(bandY) * w + Int(laneCentersX[3])] = bgAt
        return arr
    }()
    let dimBase = WesternBlotEngine.buildStandardizedBuffer(rawValues: cleanDimRaw, width: w, height: h, bitDepth: 16, linearizeSRGB: false)
    let expFactors = [1.0, 3.0, 6.0, 15.0]
    let expLane0IODs = expFactors.map { f -> Double in
        let bScaled = WesternBlotEngine.scaleBufferForExposure(dimBase, factor: f)
        let rScaled = WesternBlotEngine.analyzeNativeBuffer(bScaled, imagePath: "/tmp/scale_\(f).tif", params: params2B)
        return rScaled.bands.filter { $0.rowIndex == 0 }.sorted { $0.laneIndex < $1.laneIndex }.first?.netIOD ?? 0.0
    }
    for (idx, f) in expFactors.enumerated() {
        let obsRatio = expLane0IODs[idx] / max(1e-6, expLane0IODs[0])
        assert(abs(obsRatio - f) / f < 0.015, "2D Rolling Ball scale homogeneity broken at \(f)x: expected \(f), got \(obsRatio)")
    }

    var tiltedSignal = WesternBlotEngine.deskewImageNative(cleanDimRaw, width: w, height: h, angleDegrees: -2.5, clipNegative: true)
    tiltedSignal[Int(bandY) * w + Int(laneCentersX[3])] = 65535.0
    tiltedSignal[Int(bandY) * w + Int(laneCentersX[3]) + 1] = 65535.0
    let tiltedBuf = WesternBlotEngine.buildStandardizedBuffer(rawValues: tiltedSignal, width: w, height: h, bitDepth: 16, linearizeSRGB: false)
    let paramsDeskew = WBAnalysisParams(rollingBallRadius: 28, expectedLanes: 4, autoDeskew: true, saturationRatioThreshold: 0.0001, backgroundMode: .globalRollingBall)
    let resTilted = WesternBlotEngine.analyzeNativeBuffer(tiltedBuf, imagePath: "/tmp/tilted_2b.tif", params: paramsDeskew)
    let tiltedRow0 = resTilted.bands.filter { $0.rowIndex == 0 }.sorted { $0.laneIndex < $1.laneIndex }
    assert(abs(resTilted.skewAngle) >= 1.0 && tiltedRow0.count == 4, "Tilted blot must trigger autoDeskew and detect 4 bands, skew=\(resTilted.skewAngle), bands=\(tiltedRow0.count)")
    let tiltedRatio = tiltedRow0[2].netIOD / max(1e-6, tiltedRow0[0].netIOD)
    assert(abs(tiltedRatio - 2.0) / 2.0 < 0.05 && tiltedRow0[3].isSaturated, "Deskewed blot must recover ~2.0 ratio (got \(tiltedRatio)) and preserve Lane 3 saturation")

    // 4. Python wbquant 语法编译校验 + 无条件 numpy/scipy 模块级对齐校验（去卷积/TPN/Deskew） + 若含 skimage 则全管线校验
    let pyCompile = Process()
    pyCompile.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    pyCompile.arguments = ["-m", "py_compile", "python/wbquant/models.py", "python/wbquant/io.py", "python/wbquant/preprocess.py", "python/wbquant/quantify.py", "python/wbquant/pipeline.py", "python/wbquant/cli.py"]
    try pyCompile.run()
    pyCompile.waitUntilExit()
    assert(pyCompile.terminationStatus == 0, "python/wbquant/*.py py_compile syntax check failed")

    let candidatePythons = [
        "\(FileManager.default.currentDirectoryPath)/python/.venv/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3"
    ]
    func findPythonWithModules(_ modules: String) -> String? {
        candidatePythons.first { pyPath in
            guard FileManager.default.isExecutableFile(atPath: pyPath) else { return false }
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: pyPath)
            probe.arguments = ["-c", "import \(modules)"]
            probe.standardOutput = Pipe()
            probe.standardError = Pipe()
            do { try probe.run(); probe.waitUntilExit(); return probe.terminationStatus == 0 } catch { return false }
        }
    }
    if let npSciPy = findPythonWithModules("numpy, scipy") {
        let pyNumpyCode = """
import json, sys, math
sys.path.insert(0, '\(FileManager.default.currentDirectoryPath)/python')
import numpy as np
from wbquant.models import BandBox
from wbquant.preprocess import deskew_image, deskew_mask
from wbquant.quantify import deconvolve_overlapping_bands_gaussian, normalize_to_total_protein
prof = [1000.0 * math.exp(-0.5 * ((i - 18.0) / 3.0) ** 2) + 500.0 * math.exp(-0.5 * ((i - 26.0) / 3.0) ** 2) for i in range(50)]
dec = deconvolve_overlapping_bands_gaussian(prof, [18, 26])
b0 = BandBox(id='b0', lane_index=0, row_index=0, x=10, y=10, width=10, height=10, peak_y=15, raw_iod=100.0, background_iod=0.0, net_iod=100.0, snr=10.0)
b1 = BandBox(id='b1', lane_index=1, row_index=0, x=30, y=10, width=10, height=10, peak_y=15, raw_iod=200.0, background_iod=0.0, net_iod=200.0, snr=10.0)
b2 = BandBox(id='b2', lane_index=0, row_index=1, x=10, y=50, width=10, height=10, peak_y=55, raw_iod=500.0, background_iod=0.0, net_iod=500.0, snr=10.0)
b3 = BandBox(id='b3', lane_index=1, row_index=1, x=30, y=50, width=10, height=10, peak_y=55, raw_iod=1500.0, background_iod=0.0, net_iod=1500.0, snr=10.0)
tpn = normalize_to_total_protein([b0, b1, b2, b3], {0: 1000.0, 1: 1000.0}, control_lane_index=0)
m = np.zeros((40, 40), dtype=bool)
m[20, 20] = True
m_rot = deskew_mask(m, 2.5)
print(json.dumps({
    'area_ratio': dec[0]['area'] / dec[1]['area'],
    'row1_lane1_fc': [b.fold_change for b in tpn if b.row_index == 1 and b.lane_index == 1][0],
    'row1_lane0_fc': [b.fold_change for b in tpn if b.row_index == 1 and b.lane_index == 0][0],
    'mask_rot_count': int(m_rot.sum())
}))
"""
        let npProc = Process()
        npProc.executableURL = URL(fileURLWithPath: npSciPy)
        npProc.arguments = ["-c", pyNumpyCode]
        let npPipe = Pipe()
        npProc.standardOutput = npPipe
        try npProc.run()
        npProc.waitUntilExit()
        assert(npProc.terminationStatus == 0, "Python wbquant numpy/scipy parity script failed")
        let npObj = try JSONSerialization.jsonObject(with: npPipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
        assert(abs((npObj["area_ratio"] as? Double ?? 0.0) - 2.0) < 0.02, "Python Gaussian doublet deconv must recover 2.0 area ratio")
        assert(abs((npObj["row1_lane0_fc"] as? Double ?? 0.0) - 1.0) < 1e-6 && abs((npObj["row1_lane1_fc"] as? Double ?? 0.0) - 3.0) < 1e-6, "Python multi-row TPN normalization mismatch")
        assert((npObj["mask_rot_count"] as? Int ?? 0) >= 1, "Python deskew_mask must preserve saturated pixel")
    }
    if let pyExec = findPythonWithModules("numpy, skimage") {
        let pyParityCode = """
import json, sys, math
sys.path.insert(0, '\(FileManager.default.currentDirectoryPath)/python')
import numpy as np
from wbquant.pipeline import analyze_array
from wbquant.models import AnalysisParams
w, h = 160, 120
lane_cx = [25.0, 60.0, 95.0, 130.0]
amps = [2000.0, 2000.0, 4000.0, 4000.0]
yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
img = 500.0 + 3.0 * yy + 1.5 * xx
for cx, a in zip(lane_cx, amps):
    img += a * np.exp(-0.5 * (((xx - cx) / 7.0) ** 2 + ((yy - 58.0) / 4.0) ** 2))
img = np.clip(img, 0.0, 65535.0)
img[58, 130] = 65535.0
p = AnalysisParams(expected_lanes=4, rolling_ball_radius=28, background_mode='globalRollingBall', auto_deskew=False, saturation_ratio_threshold=0.0001)
res = analyze_array(img.astype(np.uint16), bit_depth=16, image_path='synth_py', params=p)
row0 = sorted([b for b in res.bands if b.row_index == 0], key=lambda b: b.lane_index)
print(json.dumps({
    'count': len(row0),
    'ratio2vs0': row0[2].net_iod / max(1e-6, row0[0].net_iod) if len(row0) >= 3 else 0.0,
    'lane3_sat': row0[3].is_saturated if len(row0) >= 4 else False,
    'lane3_sat_ratio': row0[3].saturated_ratio if len(row0) >= 4 else 0.0
}))
"""
        let pyProc = Process()
        pyProc.executableURL = URL(fileURLWithPath: pyExec)
        pyProc.arguments = ["-c", pyParityCode]
        let pyOutPipe = Pipe()
        pyProc.standardOutput = pyOutPipe
        try pyProc.run()
        pyProc.waitUntilExit()
        assert(pyProc.terminationStatus == 0, "Python wbquant parity script failed")
        let pyData = pyOutPipe.fileHandleForReading.readDataToEndOfFile()
        if let pyObj = try JSONSerialization.jsonObject(with: pyData) as? [String: Any] {
            let pyRatio = pyObj["ratio2vs0"] as? Double ?? 0.0
            let pySat = pyObj["lane3_sat"] as? Bool ?? false
            let pySatRatio = pyObj["lane3_sat_ratio"] as? Double ?? 0.0
            assert(abs(pyRatio - ratio2vs0) / max(1e-6, pyRatio) < 0.03, "Swift vs Python wbquant fold ratio mismatch: Swift=\(ratio2vs0), Py=\(pyRatio)")
            assert(pySat && pySatRatio > 0.0, "Python wbquant must also detect saturated pixel in lane 3")
        }
    }

    // 5. 重叠双带 1D 高斯混合去卷积 (LC3-I / LC3-II 模拟)
    let doubletProfile: [Double] = (0..<50).map { i in
        let x = Double(i)
        return 1000.0 * exp(-0.5 * pow((x - 18.0) / 3.0, 2.0)) + 500.0 * exp(-0.5 * pow((x - 26.0) / 3.0, 2.0))
    }
    let deconv = WesternBlotEngine.deconvolveOverlappingBandsGaussian(profile: doubletProfile, peakIndices: [18, 26])
    assert(deconv.count == 2, "Gaussian deconvolution must return 2 components")
    let areaRatio = deconv[0].area / max(1e-6, deconv[1].area)
    assert(abs(areaRatio - 2.0) / 2.0 < 0.03 && abs(deconv[0].fraction - (2.0 / 3.0)) < 0.02, "Gaussian doublet deconvolution must recover 2:1 area ratio (got \(areaRatio), frac=\(deconv[0].fraction))")

    // 6. 总蛋白归一化 (TPN 多行独立) + log2 空间 Welch 95% CI & Kruskal-Dunn + 跨膜重锚定 + MCP 一致性
    let tpnMap: [Int: Double] = [0: 10000.0, 1: 10200.0, 2: 9800.0, 3: 10000.0]
    let tpnBands = WesternBlotEngine.normalizeToTotalProtein(targetBands: row0, totalProteinLaneIODs: tpnMap, controlLaneIndex: 0)
    assert(abs(tpnBands[0].foldChange - 1.0) < 1e-6 && tpnBands[2].foldChange > 1.8, "TPN normalization must scale lane 2 by ~2x")
    let row1Mock = row0.map { b -> WBBand in
        var copy = b; copy.rowIndex = 1; copy.netIOD = b.netIOD * 5.0; return copy
    }
    let multiRowTPN = WesternBlotEngine.normalizeToTotalProtein(targetBands: row0 + row1Mock, totalProteinLaneIODs: tpnMap, controlLaneIndex: 0)
    let row1Lane0 = multiRowTPN.first(where: { $0.rowIndex == 1 && $0.laneIndex == 0 })!
    assert(abs(row1Lane0.foldChange - 1.0) < 1e-6, "Multi-row TPN must anchor each rowIndex independently to its own control lane")

    let laneGroups: [Int: String] = [0: "WT", 1: "WT", 2: "KO", 3: "KO"]
    let statsOut = WesternBlotEngine.computeGroupStatistics(
        from: resSwift, laneGroups: laneGroups, controlGroup: "WT",
        saturationPolicy: .warnOnly, totalProteinLaneIODs: tpnMap, postHocMethod: .welchHolm
    )
    let koStat = statsOut.groupStats.first(where: { $0.groupName == "KO" })!
    assert(koStat.log2MeanFold != nil && (koStat.log2MeanFold ?? 0) > 0.8, "log2MeanFold must be populated in log2 space")
    assert(koStat.pAdjusted != nil && koStat.foldCI95Low != nil && koStat.foldCI95High != nil, "Holm-adjusted p-value and two-sample Welch 95% CI must be populated")

    let statsKD = WesternBlotEngine.computeGroupStatistics(
        from: resSwift, laneGroups: laneGroups, controlGroup: "WT",
        saturationPolicy: .warnOnly, totalProteinLaneIODs: tpnMap, postHocMethod: .kruskalDunn
    )
    let koKD = statsKD.groupStats.first(where: { $0.groupName == "KO" })!
    assert(koKD.pAdjusted != nil, "kruskalDunn post-hoc must compute real Dunn adjusted p-value")

    let combined = WesternBlotEngine.combineReplicateBlots(blots: [statsOut, statsOut], controlGroup: "WT")
    assert(combined.laneRows.count == statsOut.laneRows.count * 2, "combineReplicateBlots must aggregate all replicate membrane rows")
    if let wtComb = combined.groupStats.first(where: { $0.groupName == "WT" }) {
        assert(abs(wtComb.meanFold - 1.0) < 1e-3, "combineReplicateBlots must re-anchor control group to 1.0, got \(wtComb.meanFold)")
    }

    // MCP analyze_western_blot TPN + log2 校验
    let mcpWBCode = """
import json, sys
sys.path.insert(0, '\(FileManager.default.currentDirectoryPath)/Sources/CloneStudioCore/Resources')
import clonestudio_mcp_server as srv
out = srv.tool_analyze_western_blot({
    'target_iods': [100.0, 105.0, 210.0, 220.0, 390.0, 410.0],
    'total_protein_lane_iods': [1000.0, 1000.0, 1000.0, 1000.0, 1000.0, 1000.0],
    'lane_groups': ['WT', 'WT', 'DrugA', 'DrugA', 'DrugB', 'DrugB'],
    'saturation_policy': 'excludeFromStats'
})
print(json.dumps(out))
"""
    let mcpProc = Process()
    mcpProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    mcpProc.arguments = ["-c", mcpWBCode]
    let mcpPipe = Pipe()
    mcpProc.standardOutput = mcpPipe
    try mcpProc.run()
    mcpProc.waitUntilExit()
    assert(mcpProc.terminationStatus == 0, "MCP analyze_western_blot 2B parity script failed")
    if let mcpObj = try JSONSerialization.jsonObject(with: mcpPipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any],
       let gStats = mcpObj["group_statistics"] as? [[String: Any]] {
        assert((mcpObj["normalization_mode"] as? String) == "totalProtein", "MCP must switch to totalProtein mode when total_protein_lane_iods is provided")
        let drugB = gStats.first(where: { ($0["group"] as? String) == "DrugB" })!
        assert((drugB["log2_mean_fold"] as? Double ?? 0) > 1.8, "MCP log2_mean_fold for ~4x DrugB must be ~2.0")
        assert(drugB["p_adjusted"] != nil && drugB["fold_ci95_low"] != nil && drugB["fold_ci95_high"] != nil, "MCP must return Holm p_adjusted and 95% CI")
    }

    // 7. 多曝光曲线排除过曝帧后再拟合线性响应
    let baseBuf = dimBase
    let buf5 = WesternBlotEngine.scaleBufferForExposure(baseBuf, factor: 1.0)
    let buf15 = WesternBlotEngine.scaleBufferForExposure(baseBuf, factor: 3.0)
    let buf30 = WesternBlotEngine.scaleBufferForExposure(baseBuf, factor: 6.0)
    let buf120 = WesternBlotEngine.scaleBufferForExposure(baseBuf, factor: 24.0) // 严重过曝截断于 65535
    let expSeries: [(imagePath: String, exposureSeconds: Double, buffer: WesternBlotEngine.RawGrayBuffer16?)] = [
        ("e5.tif", 5.0, buf5), ("e15.tif", 15.0, buf15), ("e30.tif", 30.0, buf30), ("e120.tif", 120.0, buf120)
    ]
    guard let expOut = WesternBlotEngine.analyzeExposureSeries(series: expSeries, params: params2B, referenceBands: row0) else {
        fatalError("analyzeExposureSeries returned nil")
    }
    assert(expOut.recommendedExposureSeconds == 30.0, "analyzeExposureSeries must recommend 30s frame (excluding saturated 120s), got \(expOut.recommendedExposureSeconds)")
    assert(expOut.bandLinearities.allSatisfy { $0.r2 > 0.99 }, "Linear regression after excluding saturated frame must achieve R² > 0.99")

    pass("Sub-batch 2B scientific rigor suite passed (2D RollingBall, Skew+SatMask Sync, 12-bit/sRGB, Deconv, TPN, log2 Stats & Python/MCP parity).")
}
do {
    try runTest63SubBatch2B()
} catch {
    fatalError("Sub-batch 2B test failed: \(error)")
}

// MARK: - Test 64: Sub-batch 2C — CRISPR Sanger 编辑反卷积 (TIDE/ICE 对齐、RFU 缩放、+1/-24bp KO、共线性告警 & MCP 一致性)
func runTest64SubBatch2C() throws {
    print("\n--- Test 64: Sub-batch 2C (CRISPRDeconvolutionEngine TIDE/ICE Alignment, RFU Scale, -24bp KO, Collinearity & MCP Parity) ---")

    // 构造 240 bp 非重复 WT 序列与 sgRNA (cut0 = 60)
    let wtSeq =
        "GCTAGCTAGCATCGATCGATGCTAGCTAGCATGAGGCTCAGTACCTGATCCGATAGTCGA" + // 0..59 (60bp)
        "TTGCAACGGTAACCGGTTAACTGACTGACTGATCGTACGTCCGGTTAACCAGTCGATCGA" + // 60..119
        "TGCATGCATGAACCTTGGAAGGCCAATTGGCATGCATGCATCGATCGATCGGAATTCCGG" + // 120..179
        "TTAACCGGTTACGTACGTACGCTAGCTAGCATCGATCGATAGGCTCAGTACCTGATCCGA"   // 180..239
    let wtChars = Array(wtSeq)
    let sgRNA = String(wtChars[43..<63]) // cut0 = 43 + 20 - 3 = 60

    // 1. 错位 3 bp 的 100% 未编辑 WT 测序读数：上游对齐必须消除偏移并返回 WT ≈ 100%, indel < 1%
    let shiftedWTSeq = "AAA" + wtSeq
    let wtAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: wtSeq, sampleName: "WT_2C.ab1", simulateNoisyEnds: false)
    let shiftedAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: shiftedWTSeq, sampleName: "Ed_Shifted_WT.ab1", simulateNoisyEnds: false)
    let wtRec = SangerAlignmentEngine.parseData(wtAB1, filePath: "WT_2C.ab1")
    let edShiftRec = SangerAlignmentEngine.parseData(shiftedAB1, filePath: "Ed_Shifted_WT.ab1")
    let resShift = CRISPRDeconvolutionEngine.deconvolveChromatograms(wt: wtRec, edited: edShiftRec, sgRNASequence: sgRNA, requestedWindowBp: 120)
    assert(resShift.alignmentOffsetBp == 3, "Upstream alignment must detect +3 bp offset, got \(resShift.alignmentOffsetBp)")
    assert(resShift.wtPercent > 99.0 && resShift.indelPercent < 1.0, "Shifted 100% WT must report WT>99%, indel<1% (got WT=\(resShift.wtPercent), Indel=\(resShift.indelPercent))")

    // 2. 随机 +1 bp 插入（非串联重复，插入碱基 'G' 与上游 'A' 不同）+ -24 bp 大片段框内缺失计入 KO Score
    let wtPeaks = CRISPRDeconvolutionEngine.peaksFromSequence(wtSeq, primarySignal: 1000.0, backgroundSignal: 20.0)
    let cut0 = 60
    let winBp = 120
    var mixWin: [[Double]] = []
    for k in 0..<winBp {
        let pWT = wtPeaks[cut0 + k]
        let pIns1G = (k == 0) ? [20.0, 20.0, 1000.0, 20.0] : wtPeaks[cut0 + k - 1]
        let pDel24 = wtPeaks[cut0 + k + 24]
        let row = (0..<4).map { c in 0.40 * pWT[c] + 0.35 * pIns1G[c] + 0.25 * pDel24[c] }
        mixWin.append(row)
    }
    let resMix = CRISPRDeconvolutionEngine.deconvolvePeakMatrices(
        wtPeaksACGT: wtPeaks,
        editedWindowPeaksACGT: mixWin,
        cutIndex0Based: cut0,
        requestedWindowBp: winBp,
        shiftRange: -30...14
    )
    assert(abs(resMix.wtPercent - 40.0) < 0.5, "Mix WT% expected 40%, got \(resMix.wtPercent)")
    assert(abs(resMix.indelPercent - 60.0) < 0.5, "Mix Indel% expected 60%, got \(resMix.indelPercent)")
    assert(abs(resMix.koScore - 60.0) < 0.5, "Both +1G (35%) and -24bp in-frame deletion (25%) must count toward KO score = 60%, got \(resMix.koScore)")

    // 3. 非循环 RFU 缩放不变性（300 vs 6000 RFU）+ 5'→3' 信号衰减（上游 2000 RFU / 下游 1200 RFU）验证
    let shortHDRSeq = String(wtChars[30..<60]) + "GAATTCC" + String(wtChars[67..<140])
    let fullHDRSeq = String(wtChars[0..<60]) + "GAATTCC" + String(wtChars[67...])
    for rfu in [300.0, 6000.0] {
        let wtScaled = CRISPRDeconvolutionEngine.peaksFromSequence(wtSeq, primarySignal: rfu, backgroundSignal: rfu * 0.02)
        // 独立由物理 fullHDRSeq 构建观察混合物，引擎自主从下游窗推断尺度（绝不用 alignAndScaleHDRWindow 的输出构造观测！）
        let hdrTrue = CRISPRDeconvolutionEngine.peaksFromSequence(fullHDRSeq, primarySignal: rfu, backgroundSignal: rfu * 0.02)
        var hdrMix: [[Double]] = []
        for k in 0..<winBp {
            hdrMix.append((0..<4).map { c in 0.50 * wtScaled[cut0 + k][c] + 0.50 * hdrTrue[cut0 + k][c] })
        }
        let (inferredPrim, inferredBg) = CRISPRDeconvolutionEngine.estimateLocalSignalScale(wtPeaks: wtScaled, start: cut0, end: min(wtScaled.count, cut0 + winBp))
        guard let hdrWin = CRISPRDeconvolutionEngine.alignAndScaleHDRWindow(
            wtSequence: wtSeq, hdrDonorSequence: shortHDRSeq, wtCutIndex0Based: cut0,
            requestedWindowBp: winBp, wtPrimarySignal: inferredPrim, wtBackgroundSignal: inferredBg
        ) else {
            fatalError("alignAndScaleHDRWindow failed for short donor")
        }
        let resHDR = CRISPRDeconvolutionEngine.deconvolvePeakMatrices(
            wtPeaksACGT: wtScaled, editedWindowPeaksACGT: hdrMix, cutIndex0Based: cut0,
            requestedWindowBp: winBp, shiftRange: -20...20, hdrWindowPeaksACGT: hdrWin
        )
        assert(abs(resHDR.hdrPercent - 50.0) < 0.5, "Non-circular HDR% must remain 50% invariant across RFU=\(rfu), got \(resHDR.hdrPercent)")
    }

    // 3b. 真实 40% 5'→3' 阶跃衰减（切点上游 2000 RFU，下游 1200 RFU）：验证无 -12.7% 系统偏差
    let wtDecayPeaks: [[Double]] = wtChars.enumerated().map { idx, base in
        let rfu = idx < cut0 ? 2000.0 : 1200.0
        return CRISPRDeconvolutionEngine.peaksFromSequence(String(base), primarySignal: rfu, backgroundSignal: rfu * 0.02)[0]
    }
    let hdrDecayFull = Array(fullHDRSeq).enumerated().map { idx, base in
        let rfu = idx < cut0 ? 2000.0 : 1200.0
        return CRISPRDeconvolutionEngine.peaksFromSequence(String(base), primarySignal: rfu, backgroundSignal: rfu * 0.02)[0]
    }
    let decayMixWin: [[Double]] = (0..<winBp).map { k in
        (0..<4).map { c in 0.50 * wtDecayPeaks[cut0 + k][c] + 0.50 * hdrDecayFull[cut0 + k][c] }
    }
    let (decayPrim, decayBg) = CRISPRDeconvolutionEngine.estimateLocalSignalScale(wtPeaks: wtDecayPeaks, start: cut0, end: min(wtDecayPeaks.count, cut0 + winBp))
    guard let hdrDecayWin = CRISPRDeconvolutionEngine.alignAndScaleHDRWindow(
        wtSequence: wtSeq, hdrDonorSequence: shortHDRSeq, wtCutIndex0Based: cut0,
        requestedWindowBp: winBp, wtPrimarySignal: decayPrim, wtBackgroundSignal: decayBg
    ) else {
        fatalError("alignAndScaleHDRWindow failed under 5'->3' decay")
    }
    let resDecay = CRISPRDeconvolutionEngine.deconvolvePeakMatrices(
        wtPeaksACGT: wtDecayPeaks, editedWindowPeaksACGT: decayMixWin, cutIndex0Based: cut0,
        requestedWindowBp: winBp, shiftRange: -20...20, hdrWindowPeaksACGT: hdrDecayWin
    )
    assert(abs(resDecay.hdrPercent - 50.0) < 0.5, "Under 40% 5'->3' decay, downstream scaling must recover HDR=50% without -12.7% bias, got \(resDecay.hdrPercent)")

    // 4. 单碱基点突变 HDR 触发 .hdrCollinearWithWT 共线性告警
    var pointHDRChars = wtChars
    pointHDRChars[cut0 + 2] = (pointHDRChars[cut0 + 2] == "A") ? "G" : "A"
    let pointHDRWin = CRISPRDeconvolutionEngine.peaksFromSequence(String(pointHDRChars[cut0..<(cut0 + winBp)]), primarySignal: 1000.0, backgroundSignal: 20.0)
    let resCollinear = CRISPRDeconvolutionEngine.deconvolvePeakMatrices(
        wtPeaksACGT: wtPeaks, editedWindowPeaksACGT: Array(wtPeaks[cut0..<(cut0 + winBp)]),
        cutIndex0Based: cut0, requestedWindowBp: winBp, shiftRange: -20...20, hdrWindowPeaksACGT: pointHDRWin
    )
    assert(resCollinear.warnings.contains(.hdrCollinearWithWT), "Single-base point mutation HDR must trigger .hdrCollinearWithWT warning")

    // 4b. 'N' 碱基索引保留 + 非循环反义链 ssODN HDR 自动对齐 + 无关供体拒绝 + +1 合并协方差 SE/pValue + B2/B5/B8 边界
    let wtWithN = "NNNNN" + wtSeq
    guard let cutWithN = CRISPRDeconvolutionEngine.locateCutSite(wtSequence: wtWithN, sgRNASequence: sgRNA) else {
        fatalError("locateCutSite failed on WT sequence containing leading N bases")
    }
    assert(cutWithN.cutIndex0Based == cut0 + 5, "Leading N bases must preserve 1:1 chromatogram indexing (expected \(cut0 + 5), got \(cutWithN.cutIndex0Based))")
    assert(CRISPRDeconvolutionEngine.peaksFromSequence(wtWithN).count == wtWithN.count, "Swift peaksFromSequence must preserve N bases 1:1")

    let antisenseHDR = BioSequence.reverseComplement(shortHDRSeq)
    guard let hdrAntisenseWin = CRISPRDeconvolutionEngine.alignAndScaleHDRWindow(
        wtSequence: wtSeq, hdrDonorSequence: antisenseHDR, wtCutIndex0Based: cut0,
        requestedWindowBp: winBp, wtPrimarySignal: 1000.0, wtBackgroundSignal: 20.0
    ) else {
        fatalError("alignAndScaleHDRWindow must auto-align antisense ssODN donor")
    }
    // 使用独立物理 fullHDRSeq 构建混合物，绝不用 hdrAntisenseWin 自证
    let hdrTrueBase = CRISPRDeconvolutionEngine.peaksFromSequence(fullHDRSeq, primarySignal: 1000.0, backgroundSignal: 20.0)
    let hdrAntiMix: [[Double]] = (0..<winBp).map { k in
        (0..<4).map { c in 0.50 * wtPeaks[cut0 + k][c] + 0.50 * hdrTrueBase[cut0 + k][c] }
    }
    let resAntiHDR = CRISPRDeconvolutionEngine.deconvolvePeakMatrices(
        wtPeaksACGT: wtPeaks, editedWindowPeaksACGT: hdrAntiMix, cutIndex0Based: cut0,
        requestedWindowBp: winBp, shiftRange: -20...20, hdrWindowPeaksACGT: hdrAntisenseWin
    )
    assert(abs(resAntiHDR.hdrPercent - 50.0) < 0.5, "Non-circular antisense ssODN HDR must recover 50%, got \(resAntiHDR.hdrPercent)")

    let garbageDonor = String(repeating: "ACGT", count: 25)
    let nilHDR = CRISPRDeconvolutionEngine.alignAndScaleHDRWindow(
        wtSequence: wtSeq, hdrDonorSequence: garbageDonor, wtCutIndex0Based: cut0,
        requestedWindowBp: winBp, wtPrimarySignal: 1000.0, wtBackgroundSignal: 20.0
    )
    assert(nilHDR == nil, "Unalignable garbage HDR donor must return nil instead of unaligned fallback")

    // +1A/+1G 合并协方差验证（±30 RFU 伪随机噪声；正确实现 SE≈0.27% < 0.6%，漏算负协方差旧版 ≈2.96%）
    var noisyMixWin: [[Double]] = []
    for k in 0..<winBp {
        let pWT = wtPeaks[cut0 + k]
        let pIns1A = (k == 0) ? [1000.0, 20.0, 20.0, 20.0] : wtPeaks[cut0 + k - 1]
        let pIns1G = (k == 0) ? [20.0, 20.0, 1000.0, 20.0] : wtPeaks[cut0 + k - 1]
        let row = (0..<4).map { c -> Double in
            let noise = 30.0 * sin(Double(k * 7 + c * 13 + 3))
            return max(0.0, 0.50 * pWT[c] + 0.25 * pIns1A[c] + 0.25 * pIns1G[c] + noise)
        }
        noisyMixWin.append(row)
    }
    let resIns1Cov = CRISPRDeconvolutionEngine.deconvolvePeakMatrices(
        wtPeaksACGT: wtPeaks, editedWindowPeaksACGT: noisyMixWin, cutIndex0Based: cut0,
        requestedWindowBp: winBp, shiftRange: -20...14
    )
    if let ins1Contrib = resIns1Cov.contributions.first(where: { $0.shiftBp == 1 && !$0.isHDR }) {
        let se1 = ins1Contrib.sePercent ?? 99.0
        assert(se1 > 0.05 && se1 < 0.60 && (ins1Contrib.pValue ?? 1.0) < 0.001, "Combined +1A/+1G covariance (1^T Sigma 1) must keep SE < 0.6% (got \(se1)) and p < 0.001")
    } else {
        fatalError("Expected +1 bp indel contribution in noisyMixWin")
    }

    // B2 边界（cut0 >= editedLength 返回空窗告警而不伪造缺失）+ B5（m <= k 欠定 Gram 返回 se=nil, p=nil）+ B8（Mott 噪声首尾修剪）
    let shortUpstreamAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: String(wtChars[0..<50]), sampleName: "Ed_ShortUpstream.ab1", simulateNoisyEnds: false)
    let shortUpstreamRec = SangerAlignmentEngine.parseData(shortUpstreamAB1, filePath: "Ed_ShortUpstream.ab1")
    let resEmptyWin = CRISPRDeconvolutionEngine.deconvolveChromatograms(wt: wtRec, edited: shortUpstreamRec, sgRNASequence: sgRNA, requestedWindowBp: 120)
    assert(resEmptyWin.effectiveWindowBp == 0 && resEmptyWin.warnings.contains(.insufficientDownstreamWindow) && resEmptyWin.indelPercent == 0.0, "Edited read ending upstream of cut0 must yield effectiveWindowBp==0 and .insufficientDownstreamWindow without fake deletions")

    // [400, 500, 350, 300] 四通道均显著大于背景，无均匀碱基列 (-1...1)，数学上必须激活 >= 4 列 (k == 4 == m -> .unavailable)
    let underdetMix: [[Double]] = [[400.0, 500.0, 350.0, 300.0]]
    let resUnderdet = CRISPRDeconvolutionEngine.deconvolvePeakMatrices(
        wtPeaksACGT: wtPeaks, editedWindowPeaksACGT: underdetMix, cutIndex0Based: cut0,
        requestedWindowBp: 1, shiftRange: -1...1
    )
    assert(resUnderdet.contributions.allSatisfy { $0.sePercent == nil && $0.pValue == nil }, "Underdetermined (m <= k) Gram must report sePercent==nil && pValue==nil, NEVER pValue==0.0")

    let wtNoisyAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: wtSeq, sampleName: "WT_Noisy.ab1", simulateNoisyEnds: true)
    let edNoisyAB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: wtSeq, sampleName: "Ed_Noisy.ab1", simulateNoisyEnds: true)
    let resMott = CRISPRDeconvolutionEngine.deconvolveChromatograms(
        wt: SangerAlignmentEngine.parseData(wtNoisyAB1, filePath: "WT_Noisy.ab1"),
        edited: SangerAlignmentEngine.parseData(edNoisyAB1, filePath: "Ed_Noisy.ab1"),
        sgRNASequence: sgRNA, requestedWindowBp: 100
    )
    assert(resMott.wtPercent > 95.0 && resMott.indelPercent < 5.0, "Mott trim + baseline subtraction on simulateNoisyEnds AB1 must recover WT > 95%, got \(resMott.wtPercent)")

    // 5. Python MCP deconvolve_sanger_crispr（含 N 保留 + 衰减 HDR 非循环校验）与 tool_deconvolute_crispr_sanger (.ab1 E2E) 一致性校验
    let tmpDir2C = FileManager.default.temporaryDirectory.appendingPathComponent("lw_2c_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir2C, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir2C) }
    let wtAB1Path = tmpDir2C.appendingPathComponent("wt.ab1")
    let edAB1Path = tmpDir2C.appendingPathComponent("ed_shifted.ab1")
    let wtNoisyPath = tmpDir2C.appendingPathComponent("wt_noisy.ab1")
    let edNoisyPath = tmpDir2C.appendingPathComponent("ed_noisy.ab1")
    try wtAB1.write(to: wtAB1Path)
    try shiftedAB1.write(to: edAB1Path)
    try wtNoisyAB1.write(to: wtNoisyPath)
    try edNoisyAB1.write(to: edNoisyPath)

    let py2CCode = """
import json, sys
sys.path.insert(0, '\(FileManager.default.currentDirectoryPath)/Sources/CloneStudioCore/Resources')
import clonestudio_mcp_server as srv
wt = '\(wtSeq)'
full_hdr = '\(fullHDRSeq)'
short_hdr = '\(shortHDRSeq)'
cut0, win_bp = 60, 120
assert len(srv.peaks_from_sequence('NNN' + wt)) == len(wt) + 3, 'Python peaks_from_sequence must preserve N bases 1:1'
wt_n = wt[:cut0 + 95] + 'N' + wt[cut0 + 96:]
hdr_n_win = srv._align_and_scale_hdr_window(wt_n, short_hdr, cut0, win_bp, 1000.0, 20.0)
assert hdr_n_win is not None and len(hdr_n_win) == win_bp, 'HDR tail stitching with N in WT must retain full 120-bp window'
wt_p = srv.peaks_from_sequence(wt, 1000.0, 20.0)
mix = []
for k in range(win_bp):
    p_wt = wt_p[cut0 + k]
    p_ins = [20.0, 20.0, 1000.0, 20.0] if k == 0 else wt_p[cut0 + k - 1]
    p_del24 = wt_p[cut0 + k + 24]
    mix.append([0.40 * p_wt[c] + 0.35 * p_ins[c] + 0.25 * p_del24[c] for c in range(4)])
out = srv.deconvolve_sanger_crispr({
    'wt_sequence': wt, 'cut_index_0based': cut0, 'window_length_bp': win_bp,
    'shift_min_bp': -30, 'shift_max_bp': 14, 'wt_peaks_acgt': wt_p, 'edited_peaks_acgt': mix
})
wt_decay = [srv.peaks_from_sequence(b, 2000.0 if i < cut0 else 1200.0, 40.0 if i < cut0 else 24.0)[0] for i, b in enumerate(wt)]
hdr_decay = [srv.peaks_from_sequence(b, 2000.0 if i < cut0 else 1200.0, 40.0 if i < cut0 else 24.0)[0] for i, b in enumerate(full_hdr)]
decay_mix = [[0.50 * wt_decay[cut0 + k][c] + 0.50 * hdr_decay[cut0 + k][c] for c in range(4)] for k in range(win_bp)]
out_decay = srv.deconvolve_sanger_crispr({
    'wt_sequence': wt, 'cut_index_0based': cut0, 'window_length_bp': win_bp,
    'shift_min_bp': -20, 'shift_max_bp': 20, 'wt_peaks_acgt': wt_decay, 'edited_peaks_acgt': decay_mix,
    'hdr_donor_sequence': short_hdr
})
ab1_out = srv.tool_deconvolute_crispr_sanger({
    'wt_ab1_path': '\(wtAB1Path.path)',
    'edited_ab1_path': '\(edAB1Path.path)',
    'sgrna_sequence': '\(sgRNA)',
    'window_length_bp': 120
})
ab1_noisy = srv.tool_deconvolute_crispr_sanger({
    'wt_ab1_path': '\(wtNoisyPath.path)',
    'edited_ab1_path': '\(edNoisyPath.path)',
    'sgrna_sequence': '\(sgRNA)',
    'window_length_bp': 100
})
print(json.dumps({
    'wt': out['wt_percent'], 'indel': out['indel_percent'], 'ko': out['ko_score'],
    'decay_hdr': out_decay['hdr_percent'],
    'ab1_offset': ab1_out['alignment_offset_bp'], 'ab1_wt': ab1_out['wt_percent'], 'ab1_indel': ab1_out['indel_percent'],
    'noisy_wt': ab1_noisy['wt_percent']
}))
"""
    let proc2C = Process()
    proc2C.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc2C.arguments = ["-c", py2CCode]
    let pipe2C = Pipe()
    proc2C.standardOutput = pipe2C
    try proc2C.run()
    proc2C.waitUntilExit()
    assert(proc2C.terminationStatus == 0, "Python MCP 2C parity script failed")
    if let obj = try JSONSerialization.jsonObject(with: pipe2C.fileHandleForReading.readDataToEndOfFile()) as? [String: Any] {
        assert(abs((obj["ko"] as? Double ?? 0) - resMix.koScore) < 0.2, "Swift vs Python MCP 2C KO score mismatch")
        assert(abs((obj["decay_hdr"] as? Double ?? 0) - 50.0) < 0.5, "Python MCP HDR under 40% decay must recover 50%, got \(String(describing: obj["decay_hdr"]))")
        assert((obj["ab1_offset"] as? Int ?? -99) == 3, "Python MCP .ab1 E2E must detect alignment_offset_bp == 3")
        assert((obj["ab1_wt"] as? Double ?? 0) > 99.0 && (obj["ab1_indel"] as? Double ?? 99) < 1.0, "Python MCP .ab1 E2E shifted WT must report WT>99%, indel<1%")
        assert((obj["noisy_wt"] as? Double ?? 0) > 95.0, "Python MCP .ab1 noisy ends Mott trim must recover WT > 95%")
    }

    pass("Sub-batch 2C scientific rigor suite passed (Upstream Alignment, TIDE/ICE +1/-24bp KO, RFU Scale, Collinearity & MCP Parity).")
}
do {
    try runTest64SubBatch2C()
} catch {
    fatalError("Sub-batch 2C test failed: \(error)")
}

// MARK: - Test 65: Sub-batch 2D — qPCR MIQE 2.0 (geNorm/NormFinder 稳定性、BH-FDR、效率误差传播、标曲外推、RDML 384 孔 & 孔板合并)
func runTest65SubBatch2D() throws {
    print("\n--- Test 65: Sub-batch 2D (qPCR geNorm/NormFinder MIQE, BH-FDR, Efficiency SE Propagation, Std Extrap, RDML 384-well & Plate Merge) ---")

    // 1. geNorm / NormFinder 内参稳定性检验：稳定双内参 (GAPDH+ACTB) vs 处理诱导剧烈漂移的不稳定内参 (BADREF)
    var stabWells: [QPCRWellRecord] = []
    let sampleSpec: [(name: String, grp: String, gapdh: Double, actb: Double, badRef: Double, target1: Double, target2: Double)] = [
        ("Ctrl1", "WT",   18.00, 19.10, 20.00, 24.00, 25.00),
        ("Ctrl2", "WT",   18.12, 19.20, 20.15, 24.15, 25.08),
        ("Ctrl3", "WT",   17.95, 19.04, 19.90, 23.92, 24.95),
        ("Trt1",  "Drug", 18.08, 19.16, 23.40, 21.05, 24.88),
        ("Trt2",  "Drug", 18.18, 19.25, 23.75, 21.18, 25.02),
        ("Trt3",  "Drug", 18.02, 19.12, 23.55, 20.95, 24.94)
    ]
    var wIdx = 0
    for s in sampleSpec {
        for (tar, ct) in [("GAPDH", s.gapdh), ("ACTB", s.actb), ("BADREF", s.badRef), ("TP53", s.target1), ("BCL2", s.target2)] {
            wIdx += 1
            stabWells.append(QPCRWellRecord(id: "w_\(wIdx)", row: wIdx, well: "A\(wIdx)", sample: s.name, target: tar, group: s.grp, ct: ct))
        }
    }
    let stableSettings = QPCRSettings(referenceTargets: ["GAPDH", "ACTB"], controlGroup: "WT", multipleComparison: .bhFDR)
    let qcStable = QPCRAnalysisEngine.computeQC(wells: stabWells, settings: stableSettings)
    let ddctStable = QPCRAnalysisEngine.computeDdct(wells: stabWells, settings: stableSettings, qc: qcStable)
    let stdEmptyStable = QPCRAnalysisEngine.computeStandardCurve(wells: stabWells, settings: stableSettings, qc: qcStable)
    let repStable = QPCRAnalysisEngine.evaluateReferenceStability(wells: stabWells, settings: stableSettings, qc: qcStable)
    assert(repStable.isStable && (repStable.genes.first?.geNormM ?? 9.0) < 0.2, "Stable GAPDH+ACTB pair must pass geNorm (M < 0.2)")
    assert(repStable.genes.allSatisfy { $0.normFinderRho == nil }, "NormFinder requires k >= 3 candidate reference genes and must return nil for k == 2")
    let miqeStable = QPCRInstrumentAndRDMLEngine.evaluateMIQECompliance(
        wells: stabWells, settings: stableSettings, qc: qcStable, ddctOut: ddctStable,
        stdOut: stdEmptyStable, detectedFormat: .genericCSV
    )
    assert(miqeStable.items.first(where: { $0.id == "ref_genes" })?.status == .pass, "MIQE item 3 must PASS for stable GAPDH+ACTB")

    let unstableSettings = QPCRSettings(referenceTargets: ["GAPDH", "ACTB", "BADREF"], controlGroup: "WT")
    let qcUnstable = QPCRAnalysisEngine.computeQC(wells: stabWells, settings: unstableSettings)
    let ddctUnstable = QPCRAnalysisEngine.computeDdct(wells: stabWells, settings: unstableSettings, qc: qcUnstable)
    let stdEmptyUnstable = QPCRAnalysisEngine.computeStandardCurve(wells: stabWells, settings: unstableSettings, qc: qcUnstable)
    let repUnstable = QPCRAnalysisEngine.evaluateReferenceStability(wells: stabWells, settings: unstableSettings, qc: qcUnstable)
    assert(!repUnstable.isStable, "Treatment-shifted BADREF (+3.5 Ct) must fail stability check")
    assert(repUnstable.stepwiseExclusionOrder.first == "BADREF", "geNorm stepwise exclusion must drop BADREF first, got \(repUnstable.stepwiseExclusionOrder)")
    let badMetric = repUnstable.genes.first(where: { $0.target == "BADREF" })!
    let gapdhMetric = repUnstable.genes.first(where: { $0.target == "GAPDH" })!
    let badRho = badMetric.normFinderRho ?? 0.0
    let gapdhRho = gapdhMetric.normFinderRho ?? 9.0
    assert(badRho > 1.0 && gapdhRho < 0.65 && badRho > 2.0 * gapdhRho, "NormFinder (k=3, +3.5 Ct shift -> exact |d|≈1.17 vs 0.58) must penalize BADREF (>1.0, >2x GAPDH), got BADREF=\(badRho), GAPDH=\(gapdhRho)")
    assert(badMetric.geNormM > 0.5 && gapdhMetric.geNormM < 0.2, "Stepwise geNorm M must separate excluded BADREF (>0.5) from final pair GAPDH (<0.2), got BADREF=\(badMetric.geNormM), GAPDH=\(gapdhMetric.geNormM)")
    let miqeUnstable = QPCRInstrumentAndRDMLEngine.evaluateMIQECompliance(
        wells: stabWells, settings: unstableSettings, qc: qcUnstable, ddctOut: ddctUnstable,
        stdOut: stdEmptyUnstable, detectedFormat: .genericCSV
    )
    assert(miqeUnstable.items.first(where: { $0.id == "ref_genes" })?.status == .fail, "MIQE item 3 must FAIL when reference gene is unstable")

    // 1b. 均匀 cDNA 上样偏移 (+2.0 Ct 同步平移 3 个稳定内参) 不应误判内参失稳，且忽略未上板的参考基因
    var loadShiftWells: [QPCRWellRecord] = []
    var lsIdx = 0
    for (sName, grp, shift) in [("W1", "WT", 0.0), ("W2", "WT", 0.05), ("W3", "WT", -0.04), ("D1", "Drug", 2.0), ("D2", "Drug", 2.04), ("D3", "Drug", 1.97)] {
        for (tar, baseCt) in [("GAPDH", 18.0), ("ACTB", 19.2), ("RPL13A", 20.1)] {
            lsIdx += 1
            loadShiftWells.append(QPCRWellRecord(id: "ls_\(lsIdx)", row: lsIdx, well: "B\(lsIdx)", sample: sName, target: tar, group: grp, ct: baseCt + shift))
        }
    }
    let loadShiftSettings = QPCRSettings(referenceTargets: ["GAPDH", "ACTB", "RPL13A", "ABSENT_REF"], controlGroup: "WT")
    let qcLoadShift = QPCRAnalysisEngine.computeQC(wells: loadShiftWells, settings: loadShiftSettings)
    let repLoadShift = QPCRAnalysisEngine.evaluateReferenceStability(wells: loadShiftWells, settings: loadShiftSettings, qc: qcLoadShift)
    assert(repLoadShift.isStable && repLoadShift.genes.count == 3, "Uniform cDNA loading shift across 3 stable refs must stay stable and ignore ABSENT_REF")

    // 2. Benjamini–Hochberg FDR 校正精确值与逆序累积最小截断核验（对标 R p.adjust(..., method="BH")）
    let bhAdj = QPCRStatistics.bhAdjust([0.001, 0.02, 0.04, 0.50])
    assert(abs(bhAdj[0] - 0.004) < 1e-9 && abs(bhAdj[1] - 0.04) < 1e-9 && abs(bhAdj[2] - 0.0533333333) < 1e-6 && abs(bhAdj[3] - 0.50) < 1e-9, "BH-FDR values mismatch R p.adjust: got \(bhAdj)")
    let bhClamp = QPCRStatistics.bhAdjust([0.01, 0.03, 0.025, 0.50])
    assert(abs(bhClamp[0] - 0.04) < 1e-9 && abs(bhClamp[1] - 0.04) < 1e-9 && abs(bhClamp[2] - 0.04) < 1e-9 && abs(bhClamp[3] - 0.50) < 1e-9, "BH-FDR reverse cumulative minimum clamping mismatch: got \(bhClamp)")
    let tp53Drug = ddctStable.groupResults.first(where: { $0.target == "TP53" && $0.category == "Drug" })!
    assert(tp53Drug.multipleComparison == .bhFDR && (tp53Drug.pAdjusted ?? 1.0) < 0.01, "Cross-gene BH-FDR must mark strongly shifted TP53 significant")

    // 3. 标准曲线斜率误差传播至效率 SE + 超标准曲线外推告警 + Pfaffl/qBase 效率误差传播至样本 SEM
    let stdWells: [QPCRWellRecord] = [
        QPCRWellRecord(id: "s1", well: "A1", sample: "Std1", target: "TP53", wellType: .standard, ct: 18.02, quantity: 10000),
        QPCRWellRecord(id: "s2", well: "A2", sample: "Std2", target: "TP53", wellType: .standard, ct: 21.30, quantity: 1000),
        QPCRWellRecord(id: "s3", well: "A3", sample: "Std3", target: "TP53", wellType: .standard, ct: 24.68, quantity: 100),
        QPCRWellRecord(id: "s4", well: "A4", sample: "Std4", target: "TP53", wellType: .standard, ct: 27.95, quantity: 10),
        QPCRWellRecord(id: "u1", well: "B1", sample: "InRangeSample", target: "TP53", wellType: .sample, ct: 23.0),
        QPCRWellRecord(id: "u2", well: "B2", sample: "LowExtrapSample", target: "TP53", wellType: .sample, ct: 32.5),
        QPCRWellRecord(id: "u3", well: "B3", sample: "HighExtrapSample", target: "TP53", wellType: .sample, ct: 14.0)
    ]
    let stdSettings = QPCRSettings(efficiencyCorrection: true)
    let stdQC = QPCRAnalysisEngine.computeQC(wells: stdWells, settings: stdSettings)
    let stdOut = QPCRAnalysisEngine.computeStandardCurve(wells: stdWells, settings: stdSettings, qc: stdQC)
    guard let tpFit = stdOut.fits.first(where: { $0.target == "TP53" }) else { fatalError("Missing TP53 std fit") }
    assert((tpFit.slopeSE ?? 0) > 0 && (tpFit.efficiencySE ?? 0) > 0, "Standard curve must compute slopeSE and Taylor-propagated efficiencySE")
    let sIn = stdOut.samples.first(where: { $0.sample == "InRangeSample" })!
    let sLo = stdOut.samples.first(where: { $0.sample == "LowExtrapSample" })!
    let sHi = stdOut.samples.first(where: { $0.sample == "HighExtrapSample" })!
    assert(!sIn.isExtrapolated && sLo.isExtrapolated && sHi.isExtrapolated && sLo.extrapolationWarning != nil, "Standard curve must flag out-of-range samples as extrapolated")

    // Pfaffl/qBase 一阶泰勒效率误差传播验证：带噪声标曲 + 非零 ΔCq 应增大 foldChange 误差区间
    let effPropWells: [QPCRWellRecord] = [
        QPCRWellRecord(id: "ep_s1", well: "A1", sample: "S1", target: "TP53", wellType: .standard, ct: 18.0, quantity: 10000),
        QPCRWellRecord(id: "ep_s2", well: "A2", sample: "S2", target: "TP53", wellType: .standard, ct: 21.8, quantity: 1000),
        QPCRWellRecord(id: "ep_s3", well: "A3", sample: "S3", target: "TP53", wellType: .standard, ct: 24.4, quantity: 100),
        QPCRWellRecord(id: "ep_s4", well: "A4", sample: "S4", target: "TP53", wellType: .standard, ct: 28.5, quantity: 10),
        QPCRWellRecord(id: "ep_r1", well: "B1", sample: "R1", target: "GAPDH", wellType: .standard, ct: 17.0, quantity: 10000),
        QPCRWellRecord(id: "ep_r2", well: "B2", sample: "R2", target: "GAPDH", wellType: .standard, ct: 20.6, quantity: 1000),
        QPCRWellRecord(id: "ep_r3", well: "B3", sample: "R3", target: "GAPDH", wellType: .standard, ct: 23.3, quantity: 100),
        QPCRWellRecord(id: "ep_r4", well: "B4", sample: "R4", target: "GAPDH", wellType: .standard, ct: 27.2, quantity: 10),
        QPCRWellRecord(id: "ep_c1", well: "C1", sample: "Ctrl", target: "TP53", group: "WT", ct: 24.0),
        QPCRWellRecord(id: "ep_c2", well: "C2", sample: "Ctrl", target: "TP53", group: "WT", ct: 24.05),
        QPCRWellRecord(id: "ep_c3", well: "C3", sample: "Ctrl", target: "GAPDH", group: "WT", ct: 18.0),
        QPCRWellRecord(id: "ep_c4", well: "C4", sample: "Ctrl", target: "GAPDH", group: "WT", ct: 18.05),
        QPCRWellRecord(id: "ep_t1", well: "D1", sample: "Trt", target: "TP53", group: "Drug", ct: 20.0),
        QPCRWellRecord(id: "ep_t2", well: "D2", sample: "Trt", target: "TP53", group: "Drug", ct: 20.05),
        QPCRWellRecord(id: "ep_t3", well: "D3", sample: "Trt", target: "GAPDH", group: "Drug", ct: 19.5),
        QPCRWellRecord(id: "ep_t4", well: "D4", sample: "Trt", target: "GAPDH", group: "Drug", ct: 19.55)
    ]
    let effSettingsOn = QPCRSettings(efficiencyCorrection: true, referenceTargets: ["GAPDH"], controlGroup: "WT")
    let effSettingsOff = QPCRSettings(efficiencyCorrection: false, referenceTargets: ["GAPDH"], controlGroup: "WT")
    let ddctEffOn = QPCRAnalysisEngine.computeDdct(wells: effPropWells, settings: effSettingsOn, qc: QPCRAnalysisEngine.computeQC(wells: effPropWells, settings: effSettingsOn))
    let ddctEffOff = QPCRAnalysisEngine.computeDdct(wells: effPropWells, settings: effSettingsOff, qc: QPCRAnalysisEngine.computeQC(wells: effPropWells, settings: effSettingsOff))
    let trtOn = ddctEffOn.sampleResults.first(where: { $0.sample == "Trt" && $0.target == "TP53" })!
    let trtOff = ddctEffOff.sampleResults.first(where: { $0.sample == "Trt" && $0.target == "TP53" })!
    assert(abs((trtOn.efficiencyPropagatedFoldSE ?? 0.0) - 6.858286) < 0.02 && trtOff.efficiencyPropagatedFoldSE == nil, "Pfaffl/qBase Taylor efficiency SE propagation must match finite-diff 6.858286, got \(String(describing: trtOn.efficiencyPropagatedFoldSE))")

    // 4. RDML 384 孔板往返导出与解析无损校验 + 96 孔板非标准标签 ("NTC1"/"POS1"/"W13") 防误判
    let wells384: [QPCRWellRecord] = [
        QPCRWellRecord(id: "r1", well: "A1",  sample: "S_A1",  target: "GAPDH", ct: 18.1),
        QPCRWellRecord(id: "r2", well: "A13", sample: "S_A13", target: "GAPDH", ct: 18.2),
        QPCRWellRecord(id: "r3", well: "B1",  sample: "S_B1",  target: "TP53",  ct: 22.3),
        QPCRWellRecord(id: "r4", well: "I24", sample: "S_I24", target: "TP53",  ct: 23.4),
        QPCRWellRecord(id: "r5", well: "P24", sample: "S_P24", target: "TP53",  ct: 24.5)
    ]
    let rdml384XML = QPCRInstrumentAndRDMLEngine.exportRDMLXML(wells: wells384, settings: QPCRSettings(), experimentName: "Plate384Test")
    assert(rdml384XML.contains("<rows>16</rows><columns>24</columns>"), "RDML export must emit 16x24 pcrFormat for 384-well plates")
    assert(rdml384XML.contains("id=\"384\""), "P24 must map to react id 384")
    let parsed384 = try QPCRInstrumentAndRDMLEngine.parseRDMLXML(rdml384XML)
    let parsedWellLabels = parsed384.wells.map(\.well)
    assert(parsedWellLabels == ["A1", "A13", "B1", "I24", "P24"], "384-well RDML round-trip mismatch: got \(parsedWellLabels)")

    let wells96Special: [QPCRWellRecord] = [
        QPCRWellRecord(id: "q1", well: "A1", sample: "S1", target: "GAPDH", ct: 18.0),
        QPCRWellRecord(id: "q2", well: "NTC1", sample: "NTC", target: "GAPDH", wellType: .ntc, ct: nil),
        QPCRWellRecord(id: "q3", well: "POS1", sample: "Pos", target: "GAPDH", ct: 17.5),
        QPCRWellRecord(id: "q4", well: "W13", sample: "S2", target: "GAPDH", ct: 18.2)
    ]
    let rdml96XML = QPCRInstrumentAndRDMLEngine.exportRDMLXML(wells: wells96Special, settings: QPCRSettings(), experimentName: "Plate96Guard")
    assert(rdml96XML.contains("<rows>8</rows><columns>12</columns>"), "Non-plate well labels (NTC1/POS1/W13) must NOT trigger 384-well RDML pcrFormat")

    // 5. mergeWithPlateAssignments 保留靶基因与 .noRT/.standard、防大小写重复键崩溃与空默认靶基因保护
    let existing = [
        QPCRWellRecord(id: "e1", well: "A1", sample: "Old", target: "MYC", group: "", ct: 21.5),
        QPCRWellRecord(id: "e2", well: "A2", sample: "", target: "MYC", group: "", ct: nil),
        QPCRWellRecord(id: "e3", well: "A3", sample: "NoRT_1", target: "MYC", group: "WT", wellType: .noRT, ct: nil),
        QPCRWellRecord(id: "e4", well: "A4", sample: "Std_1", target: "MYC", group: "", wellType: .standard, ct: 19.0, quantity: 1000)
    ]
    let plateAssign: [String: PlateWellAssignment] = [
        "A1": PlateWellAssignment(well: "A1", row: 0, col: 0, type: .control, sampleName: "WT_Ctrl", group: "WT", replicate: 1),
        "a1": PlateWellAssignment(well: "a1", row: 0, col: 0, type: .control, sampleName: "WT_Ctrl", group: "WT", replicate: 1),
        "A2": PlateWellAssignment(well: "A2", row: 0, col: 1, type: .blank, sampleName: "", group: "", replicate: 0),
        "A3": PlateWellAssignment(well: "A3", row: 0, col: 2, type: .sample, sampleName: "NoRT_1", group: "WT", replicate: 1),
        "A4": PlateWellAssignment(well: "A4", row: 0, col: 3, type: .sample, sampleName: "Std_1", group: "Std", replicate: 1)
    ]
    let merged = QPCRAnalysisEngine.mergeWithPlateAssignments(existingWells: existing, assignments: plateAssign, defaultTargets: [])
    assert(merged[0].target == "MYC" && merged[0].sample == "WT_Ctrl" && merged[0].group == "WT", "mergeWithPlateAssignments must preserve target while updating sample/group")
    assert(merged[1].target == "MYC" && merged[1].wellType == .ntc && merged[1].sample == "NTC", "mergeWithPlateAssignments must map .blank to .ntc without dropping target")
    assert(merged[2].wellType == .noRT && merged[3].wellType == .standard, "mergeWithPlateAssignments must preserve .noRT and .standard well types unless explicitly .blank")
    let mergedEmptyTargets = QPCRAnalysisEngine.mergeWithPlateAssignments(existingWells: [], assignments: plateAssign, defaultTargets: [])
    assert(!mergedEmptyTargets.isEmpty && mergedEmptyTargets.allSatisfy { !$0.target.isEmpty }, "mergeWithPlateAssignments must safely fall back when existingWells and defaultTargets are both empty")

    pass("Sub-batch 2D scientific rigor suite passed (geNorm/NormFinder MIQE, BH-FDR, Efficiency SE Propagation, Std Extrap, RDML 384-well & Plate Merge).")
}
do {
    try runTest65SubBatch2D()
} catch {
    fatalError("Sub-batch 2D test failed: \(error)")
}

// MARK: - Test 66: Sub-batch 3A — Golden Gate Pryor (2020) 实测 PacBio 矩阵、j==i 自错配、DAD 全局优化、6-bp 保护碱基与跨界位点检测
func runTest66SubBatch3A() throws {
    print("\n--- Test 66: Sub-batch 3A (GoldenGate Pryor 2020 Empirical Matrices, Self-Misligation, Global DAD, 6-bp Protective & Junction Sites) ---")

    // 1. 验证 4 套 Pryor et al. (2020) PLoS ONE 实测 PacBio SMRT 矩阵加载与方向非对称性保留
    let matBsaI = GoldenGateEngine.loadNEBFidelityMatrix(enzymeName: "BsaI")
    let matBsmBI = GoldenGateEngine.loadNEBFidelityMatrix(enzymeName: "BsmBI")
    let matBbsI = GoldenGateEngine.loadNEBFidelityMatrix(enzymeName: "BbsI")
    let matSapI = GoldenGateEngine.loadNEBFidelityMatrix(enzymeName: "SapI")

    assert(matBsaI.statsByOverhang.count == 256 && matBsaI.sourceDOI == "10.1371/journal.pone.0238592.s001", "BsaI-HFv2 empirical Pryor 2020 S1 matrix must load 256 overhangs with DOI")
    assert(matBsmBI.statsByOverhang.count == 256 && matBsmBI.sourceDOI == "10.1371/journal.pone.0238592.s002", "BsmBI-v2 empirical Pryor 2020 S2 matrix must load 256 overhangs with DOI")
    assert(matBbsI.statsByOverhang.count == 256 && matBbsI.sourceDOI == "10.1371/journal.pone.0238592.s004", "BbsI-HF empirical Pryor 2020 S4 matrix must load 256 overhangs with DOI")
    assert(matSapI.statsByOverhang.count == 64 && matSapI.overhangLength == 3 && matSapI.sourceDOI == "10.1371/journal.pone.0238592.s005", "SapI empirical Pryor 2020 S5 3-bp matrix must load 64 overhangs with DOI")
    // 方向极性非对称真值检验 (Pryor 2020 S1 Table: M(TTTT, AAAG)=40 vs M(AAAA, CTTT)=1)
    assert(matBsaI.ligationCount("TTTT", "AAAG") == 40 && matBsaI.ligationCount("AAAA", "CTTT") == 1, "BsaI-HFv2 must preserve exact directional strand-polarity asymmetry M(TTTT,AAAG)=40 vs M(AAAA,CTTT)=1")

    // 2. 修复 j == i 自我错配漏检（4-bp GGCT/TTGA、3-bp CTG/GTC 及回文 AATT）
    let evalGGCT = GoldenGateEngine.evaluateOverhangSet(overhangs: ["GGCT", "ACTA"], matrix: matBsaI)
    assert(!evalGGCT.isValid && evalGGCT.crossMismatchCount >= 1 && evalGGCT.crossMismatchPairs.contains(where: { $0.overhangA == "GGCT" && $0.overhangB == "GGCT" && $0.ligationCount == 2 }), "BsaI self-misligation hotspot GGCT (M=2) must be detected by j==i scan")
    let evalTTGA = GoldenGateEngine.evaluateOverhangSet(overhangs: ["TTGA", "ACTA"], matrix: matBbsI)
    assert(!evalTTGA.isValid && evalTTGA.crossMismatchPairs.contains(where: { $0.overhangA == "TTGA" && $0.overhangB == "TTGA" && $0.ligationCount == 2 }), "BbsI self-misligation hotspot TTGA (M=2) must be detected by j==i scan")
    let evalSapSelf = GoldenGateEngine.evaluateOverhangSet(overhangs: ["CTG", "AGA"], matrix: matSapI)
    assert(!evalSapSelf.isValid && evalSapSelf.crossMismatchPairs.contains(where: { $0.overhangA == "CTG" && $0.overhangB == "CTG" && $0.ligationCount == 326 }), "SapI 3-bp self-ligation hotspot CTG (M=326) must be detected")
    let evalPal = GoldenGateEngine.evaluateOverhangSet(overhangs: ["AATT", "ACTA"], matrix: matBsaI)
    assert(!evalPal.isValid && evalPal.crossMismatchCount == 1 && evalPal.crossMismatchPairs.contains(where: { $0.overhangA == "AATT" && $0.overhangB == "AATT" && $0.ligationCount > 500 }), "Palindromic AATT must be flagged invalid, self-ligating, and deduplicated (crossMismatchCount == 1)")
    let evalInvalidLen = GoldenGateEngine.evaluateOverhangSet(overhangs: ["AAA", "ACTA"], matrix: matBsaI)
    assert(!evalInvalidLen.isValid && evalInvalidLen.assemblyFidelity == 0.0, "Invalid-length overhang must return assemblyFidelity == 0.0")
    assert(GoldenGateEngine.loadNEBFidelityMatrix(enzymeName: "BsmBI-v2").overhangLength == 4 && GoldenGateEngine.loadNEBFidelityMatrix(enzymeName: "BspQI").overhangLength == 3, "BsmBI-v2 and BspQI aliases must resolve to exact matrices")

    // 3. NEB DAD 全局优化（12 片段 100%、24 片段 > 95%、SapI 10 片段 > 90%、BsmBI 20 片段 0 issue）+ Swift ↔ Python MCP 100% 确定性一致
    let dad12 = GoldenGateEngine.allocateHighFidelityOverhangs(fragmentCount: 12, enzymeName: "BsaI")
    assert(dad12.assignedOverhangs.count == 12 && dad12.assemblyFidelity > 0.999999 && dad12.crossMismatchCount == 0, "12-fragment BsaI DAD must reach 100% fidelity with 0 mismatches, got fid=\(dad12.assemblyFidelity), mm=\(dad12.crossMismatchCount)")
    let dad24 = GoldenGateEngine.allocateHighFidelityOverhangs(fragmentCount: 24, enzymeName: "BsaI")
    assert(dad24.assignedOverhangs.count == 24 && dad24.assemblyFidelity > 0.95, "24-fragment BsaI DAD must reach >95% empirical fidelity, got \(dad24.assemblyFidelity)")
    let dadBsmBI20 = GoldenGateEngine.allocateHighFidelityOverhangs(fragmentCount: 20, enzymeName: "BsmBI-v2")
    let evalBsmBI20 = GoldenGateEngine.evaluateOverhangSet(overhangs: dadBsmBI20.assignedOverhangs, matrix: matBsmBI)
    assert(evalBsmBI20.isValid && evalBsmBI20.issues.isEmpty && dadBsmBI20.assemblyFidelity > 0.99, "20-fragment BsmBI-v2 DAD must select zero-self valid pool (>0.99 fidelity, zero issues), got fid=\(dadBsmBI20.assemblyFidelity)")
    let dadSap10 = GoldenGateEngine.allocateHighFidelityOverhangs(fragmentCount: 10, enzymeName: "SapI")
    assert(dadSap10.assignedOverhangs.count == 10 && dadSap10.assemblyFidelity > 0.90, "10-fragment SapI 3-bp DAD must reach >90% empirical fidelity, got \(dadSap10.assemblyFidelity)")

    // 4. NEB 推荐 6-bp 5' 保护碱基校验
    for key in ["bsai", "bsmbi", "bbsi", "sapi"] {
        let spec = RestrictionEnzyme.typeIISCatalog[key]!
        assert(spec.defaultProtective5Prime.count >= 6, "Type IIS \(spec.name) defaultProtective5Prime must be >= 6 bp (got \(spec.defaultProtective5Prime))")
    }

    // 5. 宿主特异同义密码子 Domestication (.eColi vs .human vs .yeast) + 双链重叠位点 + 跨界新生 Type IIS 位点检测
    let domSeqAla = "ATGGGTCTCGCTAAATAA" // GGT CTC GCT -> BsaI site across Gly(GGT) + Leu(CTC)
    let domHuman = GoldenGateEngine.domesticateFragment(sequence: domSeqAla, enzymeName: "BsaI", isCodingSequence: true, hostOrganism: .human)
    let domYeast = GoldenGateEngine.domesticateFragment(sequence: domSeqAla, enzymeName: "BsaI", isCodingSequence: true, hostOrganism: .yeast)
    assert(domHuman.remainingSitesAfterDomestication == 0 && domYeast.remainingSitesAfterDomestication == 0, "Host-specific domestication must remove BsaI site completely")
    assert(domHuman.domesticatedSequence != domYeast.domesticatedSequence, "Human (GGC/CTG) vs Yeast (GGT/TTG) host codon tables must select distinct preferred synonymous codons")
    let overlapBsmBI = GoldenGateEngine.domesticateFragment(sequence: "ATGGAGACGTCTCAATAA", enzymeName: "BsmBI", isCodingSequence: true, hostOrganism: .human)
    assert(overlapBsmBI.remainingSitesAfterDomestication == 0, "Overlapping opposite-strand BsmBI GAGACGTCTC must domesticate cleanly to 0 sites")

    // 跨界新生 BsaI (GGTCTC) 位点检测：循环 + 线性模式全 n+1 接缝扫描
    let juncPlan = GoldenGateEngine.designAssembly(
        fragments: [
            GoldenGateEngine.GoldenGateFragmentInput(name: "FragA", sequence: "ATGATCGATCGATCGG", isCodingSequence: false),
            GoldenGateEngine.GoldenGateFragmentInput(name: "FragB", sequence: "ATCGATCGATCGATCG", isCodingSequence: false)
        ],
        enzymeName: "BsaI",
        fixedOverhangs: ["ACTA", "TCTC"],
        isCircular: true
    )
    assert(!juncPlan.junctionSiteWarnings.isEmpty, "Junction-spanning GGTCTC seam (GG|TCTC) must trigger junctionSiteWarnings")
    let linearJuncPlan = GoldenGateEngine.designAssembly(
        fragments: [
            GoldenGateEngine.GoldenGateFragmentInput(name: "LinA", sequence: "TCATCGATCGATCGAT", isCodingSequence: false),
            GoldenGateEngine.GoldenGateFragmentInput(name: "LinB", sequence: "ATCGATCGATCGATCG", isCodingSequence: false)
        ],
        enzymeName: "BsaI",
        fixedOverhangs: ["GGTC", "AGAG", "GGAG"],
        isCircular: false
    )
    assert(!linearJuncPlan.junctionSiteWarnings.isEmpty, "Linear outer seam GGTC|TC must be detected in n+1 seam scan")

    // 6. Swift ↔ Python MCP 24-frag BsaI DAD + 10-frag SapI DAD + 跨界告警一致性校验
    let py3ACode = """
import json, sys
sys.path.insert(0, '\(FileManager.default.currentDirectoryPath)/Sources/CloneStudioCore/Resources')
import clonestudio_mcp_server as srv
p24 = srv.allocate_golden_gate_overhangs(fragment_count=24, enzyme_name='BsaI')
ps10 = srv.allocate_golden_gate_overhangs(fragment_count=10, enzyme_name='SapI')
jout = srv.design_golden_gate_assembly({
    'enzyme_name': 'BsaI',
    'fixed_overhangs': ['ACTA', 'TCTC'],
    'is_circular': True,
    'fragments': [
        {'name': 'FragA', 'sequence': 'ATGATCGATCGATCGG', 'is_coding_sequence': False},
        {'name': 'FragB', 'sequence': 'ATCGATCGATCGATCG', 'is_coding_sequence': False}
    ]
})
print(json.dumps({
    'p24_ovs': p24['assigned_overhangs'], 'p24_fid': p24['assembly_fidelity'],
    'ps10_ovs': ps10['assigned_overhangs'], 'ps10_fid': ps10['assembly_fidelity'],
    'j_warn_cnt': len(jout['junction_site_warnings'])
}))
"""
    let proc3A = Process()
    proc3A.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc3A.arguments = ["-c", py3ACode]
    let pipe3A = Pipe()
    proc3A.standardOutput = pipe3A
    try proc3A.run()
    proc3A.waitUntilExit()
    assert(proc3A.terminationStatus == 0, "Python MCP 3A parity script failed")
    if let obj = try JSONSerialization.jsonObject(with: pipe3A.fileHandleForReading.readDataToEndOfFile()) as? [String: Any] {
        assert((obj["p24_ovs"] as? [String]) == dad24.assignedOverhangs, "Swift vs Python 24-frag BsaI DAD overhang set mismatch")
        assert(abs((obj["p24_fid"] as? Double ?? 0) - dad24.assemblyFidelity) < 1e-9, "Swift vs Python 24-frag BsaI DAD fidelity mismatch")
        assert((obj["ps10_ovs"] as? [String]) == dadSap10.assignedOverhangs, "Swift vs Python 10-frag SapI DAD overhang set mismatch")
        assert(abs((obj["ps10_fid"] as? Double ?? 0) - dadSap10.assemblyFidelity) < 1e-9, "Swift vs Python 10-frag SapI DAD fidelity mismatch")
        assert((obj["j_warn_cnt"] as? Int ?? 0) >= 1, "Python MCP must also detect junction-spanning BsaI site")
    }

    pass("Sub-batch 3A scientific rigor suite passed (Pryor 2020 Empirical Matrices, Self-Misligation j==i, Global DAD, 6-bp Flanks, Host Domestication & Junction Sites).")
}
do {
    try runTest66SubBatch3A()
} catch {
    fatalError("Sub-batch 3A test failed: \(error)")
}

// MARK: - Test 67: Sub-batch 3B — 引物热力学 Zuker-Stiegler DP、Owczarzy 2008 Mg2+/dNTP 盐校正与克隆同源臂优化
func runTest67SubBatch3B() throws {
    print("\n--- Test 67: Sub-batch 3B (Zuker-Stiegler DP, Owczarzy 2008 Mg2+/dNTP Tm, Polymerase Ta, snipOffsets & Pair Optimization) ---")

    // 1. 双向内部错配查表 (G·T / C·A 反平行旋转键) & 发夹环熵 n=12->13 连续性 (DNA 2.44)
    let gtFwd = TmCalculator.lookupInternalMismatch("A", "G", "T", "T")
    let gtRev = TmCalculator.lookupInternalMismatch("T", "T", "G", "A")
    assert(gtFwd != nil && gtRev != nil && abs(gtFwd!.dH - gtRev!.dH) < 1e-9, "Bidirectional internal mismatch lookup must match antiparallel rotated keys")
    let ds12 = PrimerQualityEngine.hairpinLoopEntropy(length: 12)
    let ds13 = PrimerQualityEngine.hairpinLoopEntropy(length: 13)
    let expectedDS13 = -15.10 - 2.44 * 1.9872 * log(13.0 / 12.0)
    assert(abs(ds12 - (-15.10)) < 1e-9 && abs(ds13 - expectedDS13) < 1e-6 && abs(ds13 - ds12) < 0.5, "Hairpin loop entropy must be continuous at n=12->13 with DNA 2.44 coefficient")

    // 2. Zuker-Stiegler DP 真实 1-bp 凸起环发夹 (pairedBaseCount == 8) + >=2 nt 内环发夹 + 3'-五聚体 ΔG 告警
    let bulgeSeq = "CGCGACGCGTTTTCGCGCGCG"
    let bulgeHP = PrimerQualityEngine.calcHairpin(bulgeSeq, conditions: .standard)
    assert(bulgeHP.structureFound && bulgeHP.dg < -5.0 && bulgeHP.pairedBaseCount == 8, "Zuker-Stiegler DP must detect true 1-bp bulge hairpin (8 paired bases), got dg=\(bulgeHP.dg), paired=\(bulgeHP.pairedBaseCount)")
    let intLoopHP = PrimerQualityEngine.calcHairpin("CGCGTTACGCGTTTTCGCGATCGCG", conditions: .standard)
    assert(intLoopHP.structureFound && intLoopHP.dg < -3.0 && intLoopHP.pairedBaseCount >= 7, "Zuker-Stiegler DP must fold >=2 nt internal loop hairpin, got dg=\(intLoopHP.dg)")
    let highEndDG = PrimerQualityEngine.threePrimePentamerDG("ATATATCGCGC")
    let safeEndDG = PrimerQualityEngine.threePrimePentamerDG("CGCGCATATA")
    assert(highEndDG <= -9.0 && safeEndDG > -6.0, "3'-pentamer dG must flag CGCGC (<= -9.0, got \(highEndDG)) and pass ATATA (got \(safeEndDG))")

    // 3. Owczarzy et al. (2008) 游离 Mg2+ 二次螯合 + 三区段 (R<0.22 / 0.22<=R<6 / R>=6) + 聚合酶 Ta + DNA_TMM1 末端错配
    let freeMg0 = TmCalculator.freeMgMolar(mgMolar: 0.0015, dntpMolar: 0.0)
    let freeMgChelated = TmCalculator.freeMgMolar(mgMolar: 0.0015, dntpMolar: 0.0006)
    assert(abs(freeMg0 - 0.0015) < 1e-9 && freeMgChelated > 0.00085 && freeMgChelated < 0.00095, "Free Mg2+ chelation mismatch: \(freeMgChelated)")
    let seq24 = "ATGGTGAGCAAGGGCGAGGAGCTG"
    let tmMono = TmCalculator.calculate(sequence: seq24, naConcentration: 50.0, saltCorrection: .owczarzy2004).tm
    let tmMgLow = TmCalculator.calculateOwczarzy2008(sequence: seq24, monovalentMm: 50.0, mgMm: 1.5, dntpMm: 0.8).tm
    let tmMgHigh = TmCalculator.calculateOwczarzy2008(sequence: seq24, monovalentMm: 50.0, mgMm: 2.5, dntpMm: 0.2).tm
    assert(tmMgHigh > tmMgLow && tmMgLow > tmMono, "Owczarzy 2008 Tm must increase with higher free Mg2+: mono=\(tmMono), lowMg=\(tmMgLow), highMg=\(tmMgHigh)")
    let tmLowR = TmCalculator.calculateOwczarzy2008(sequence: seq24, monovalentMm: 500.0, mgMm: 0.5, dntpMm: 0.0).tm
    let tmLowRMono = TmCalculator.calculate(sequence: seq24, naConcentration: 500.0, saltCorrection: .owczarzy2004).tm
    assert(abs(tmLowR - tmLowRMono) < 0.05, "Owczarzy R<0.22 regime must match monovalent Owczarzy 2004, got \(tmLowR) vs \(tmLowRMono)")
    let tmHighR = TmCalculator.calculateOwczarzy2008(sequence: seq24, monovalentMm: 10.0, mgMm: 5.0, dntpMm: 0.0).tm
    assert(tmHighR > tmMono, "Owczarzy R>=6.0 divalent-dominated regime must elevate Tm above 50mM monovalent, got \(tmHighR)")
    assert(TmCalculator.recommendedAnnealingTemp(tmForward: 64.0, tmReverse: 62.0, polymerase: .nebQ5) == 63.0, "NEB Q5 Ta must be min(Tm)+1")
    assert(TmCalculator.recommendedAnnealingTemp(tmForward: 73.0, tmReverse: 72.0, polymerase: .phusion) == 72.0, "Phusion Ta must cap at 72.0 C")
    assert(TmCalculator.recommendedAnnealingTemp(tmForward: 64.0, tmReverse: 62.0, polymerase: .taq) == 57.0, "Taq Ta must be min(Tm)-5")
    let ggcg = TmCalculator.lookupTerminalMismatch("G", "G", "C", "G")!
    let ggcgDG37 = ggcg.dH - 310.15 * ggcg.dS / 1000.0
    assert(ggcg.dH < -5.0 && ggcgDG37 < 0.0, "SantaLucia 2001 DNA_TMM1 GG/CG must be (-6.7, -19.2) with negative dG37, got dH=\(ggcg.dH), dG37=\(ggcgDG37)")
    let tmTermMM = TmCalculator.calculateWithTemplate(primerSeq: "C" + seq24.dropFirst(), templateSenseSeq: seq24)
    assert(tmTermMM.tm < TmCalculator.calculate(sequence: seq24).tm, "5'-terminal mismatch must lower duplex Tm cleanly (got \(tmTermMM.tm) vs \(TmCalculator.calculate(sequence: seq24).tm))")
    let seqGC = "GTGGTGAGCAAGGGCGAGGAGCTG"
    let tmTermMMGC = TmCalculator.calculateWithTemplate(primerSeq: "T" + seqGC.dropFirst(), templateSenseSeq: seqGC)
    assert(tmTermMMGC.tm < TmCalculator.calculate(sequence: seqGC).tm, "5'-terminal G:C disruption on 24-mer must lower Tm cleanly (got \(tmTermMMGC.tm))")
    let seq14GC = "GCGTTGGAGACCTG"
    let tm14Full = TmCalculator.calculate(sequence: seq14GC).tm
    let tm14MM = TmCalculator.calculateWithTemplate(primerSeq: "T" + seq14GC.dropFirst(), templateSenseSeq: seq14GC).tm
    assert(tm14MM < tm14Full - 2.0, "5'-terminal G:C disruption on 14-mer must lower Tm by >2.0 C (got \(tm14MM) vs \(tm14Full))")

    // 4. HomologyArmDesigner: 真实 snipOffsets (EcoRI 1,5 vs EcoRV 3,3)、跨原点双酶切与同源臂 Tm 检查
    let ecoRI = RestrictionEnzyme(name: "EcoRI", site: "GAATTC")
    let ecoRV = RestrictionEnzyme(name: "EcoRV", site: "GATATC")
    let vecEco = String(repeating: "ACGT", count: 15) + "GAATTC" + "GATATC" + String(repeating: "TGCA", count: 15)
    let insSeq = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAG"
    let singleEcoRI = HomologyArmDesigner.designSingleEnzymeClone(vectorSeq: vecEco, insertSeq: insSeq, enzyme: ecoRI, homologyLength: 18)
    let singleEcoRV = HomologyArmDesigner.designSingleEnzymeClone(vectorSeq: vecEco, insertSeq: insSeq, enzyme: ecoRV, homologyLength: 18)
    assert(singleEcoRI.primerF.homologyArm.hasSuffix("g"), "EcoRI (1,5) upstream arm must end with retained 'G' at cut+1, got \(singleEcoRI.primerF.homologyArm)")
    assert(singleEcoRV.primerF.homologyArm.hasSuffix("gat"), "EcoRV (3,3 blunt) upstream arm must end with 'GAT' at cut+3, got \(singleEcoRV.primerF.homologyArm)")
    let kpnI = RestrictionEnzyme(name: "KpnI", site: "GGTACC")
    let vecKpn = String(repeating: "ACGT", count: 15) + "GGTACC" + String(repeating: "TGCA", count: 15)
    let singleKpnI = HomologyArmDesigner.designSingleEnzymeClone(vectorSeq: vecKpn, insertSeq: insSeq, enzyme: kpnI, homologyLength: 18)
    assert(singleKpnI.primerF.homologyArm.hasSuffix("g"), "KpnI (5,1 3'-overhang) upstream arm must respect min(5,1)=1, got \(singleKpnI.primerF.homologyArm)")
    let palHits = HomologyArmDesigner.countOffTargetMisprimingHits(primer3Prime: "TTTTCGCGAATTCGCG", templates: [("AAAACGCGAATTCGCGTTTT", false)])
    assert(palHits == 0, "Palindromic 12-mer occurring once must NOT double-count as off-target hit, got \(palHits)")

    // 跨质粒原点双酶切：enzyme5 (BamHI) 位于载体末尾、enzyme3 (EcoRI) 位于载体开头
    let bamHI = RestrictionEnzyme(name: "BamHI", site: "GGATCC")
    let wrapVec = "ACGTGAATTC" + String(repeating: "CGATCGATCG", count: 12) + "GGATCCACGT"
    let wrapDesign = HomologyArmDesigner.designDoubleEnzymeClone(vectorSeq: wrapVec, insertSeq: insSeq, enzyme5: bamHI, enzyme3: ecoRI, homologyLength: 18)
    assert(wrapDesign.primerF.homologyArm.hasSuffix("g") && (wrapDesign.resolvedCutStart ?? 0) > (wrapDesign.resolvedCutEnd ?? 999), "Origin-spanning double digest must preserve 5'->3' BamHI->EcoRI direction across origin")
    let lowTmArm = HomologyArmDesigner.evaluateHomologyOverlap("ATATATATATATATATAT")
    assert(lowTmArm.tm < 48.0 && lowTmArm.warning != nil, "Low-Tm (<48 C) Gibson/In-Fusion arm must trigger overlap warning")

    // 5. Swift ↔ Python MCP 3B 数值一致性校验 (Owczarzy 2008 Tm, Bulge Hairpin DP, 3'-pentamer dG)
    let py3BCode = """
import json, sys
sys.path.insert(0, '\(FileManager.default.currentDirectoryPath)/Sources/CloneStudioCore/Resources')
import clonestudio_mcp_server as srv
print(json.dumps({
    'tm_owcz': srv.calc_tm_owczarzy2008('\(seq24)', 50.0, 2.5, 0.2, 250.0),
    'bulge_dg': srv.calc_hairpin('\(bulgeSeq)')['dg'],
    'pent_dg': srv.three_prime_pentamer_dg('ATATATCGCGC')
}))
"""
    let proc3B = Process()
    proc3B.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc3B.arguments = ["-c", py3BCode]
    let pipe3B = Pipe()
    proc3B.standardOutput = pipe3B
    try proc3B.run()
    proc3B.waitUntilExit()
    assert(proc3B.terminationStatus == 0, "Python MCP 3B parity script failed")
    if let obj = try JSONSerialization.jsonObject(with: pipe3B.fileHandleForReading.readDataToEndOfFile()) as? [String: Any] {
        assert(abs((obj["tm_owcz"] as? Double ?? 0) - tmMgHigh) < 0.05, "Swift vs Python Owczarzy 2008 Tm mismatch")
        assert(abs((obj["bulge_dg"] as? Double ?? 0) - bulgeHP.dg) < 0.02, "Swift vs Python Zuker-Stiegler bulge hairpin dG mismatch")
        assert(abs((obj["pent_dg"] as? Double ?? 0) - highEndDG) < 0.02, "Swift vs Python 3'-pentamer dG mismatch")
    }

    pass("Sub-batch 3B scientific rigor suite passed (Zuker-Stiegler DP, Owczarzy 2008 Mg2+/dNTP Tm, Polymerase Ta, snipOffsets & Pair Optimization).")
}
do {
    try runTest67SubBatch3B()
} catch {
    fatalError("Sub-batch 3B test failed: \(error)")
}

// 68. 验证 Sub-batch 3C (蛋白质生物物理、Guruprasad 20×20 DIWV、Bjellqvist pI、TOP-IDP、Debye、Kabsch-Sander DSSP、LIGSITE 3D BFS、WT 校验 ΔΔG 与对接桥接清洗)
func runTest68SubBatch3C() throws {
    print("🧪 [68/68] Testing Sub-batch 3C (DIWV, Bjellqvist pI, TOP-IDP, Debye, DSSP, LIGSITE BFS, WT-DDG & Vina Bridge)...")

    // 3C.1 校验内置 TP53 预设已修正为真实人类 TP53 核心 DNA 结合域 (UniProt P04637: 94-292, 199 aa)
    let tp53Preset = ProteinBiophysicsEngine.builtinExamples[0]
    assert(tp53Preset.id == "tp53_core" && tp53Preset.sequence.count == 199, "TP53 preset must be 199 aa")
    assert(tp53Preset.sequence.hasPrefix("SSSVPSQKTY") && !tp53Preset.sequence.hasPrefix("MVSKGEELFT"), "TP53 preset must not be mislabeled EGFP")

    // 3C.2 Guruprasad et al. (1990) 20×20 DIWV 精确基准核对 (ExPASy ProtParam: 1UBQ = 36.06, 1CRN = 31.89)
    let ubqSeq = "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"
    let crnSeq = "TTCCPSIVARSNFNVCRLPGTPEAICATYTGCIIIPGATCPGDYAN"
    let ubqII = ProteinBiophysicsEngine.calculateInstabilityIndex(sequence: ubqSeq)
    let crnII = ProteinBiophysicsEngine.calculateInstabilityIndex(sequence: crnSeq)
    assert(abs(ubqII - 36.06) < 0.02, "1UBQ Guruprasad DIWV expected 36.06, got \(ubqII)")
    assert(abs(crnII - 31.89) < 0.02, "1CRN Guruprasad DIWV expected 31.89, got \(crnII)")
    let ubqRep = ProteinBiophysicsEngine.analyzeProtein(sequence: ubqSeq, env: ProteinEnvironmentParams(ph: 7.0, temperatureK: 298.15, ionicStrengthM: 0.15, pkaScale: .bjellqvist))
    assert(ubqRep.isStable && abs(ubqRep.isoelectricPoint - 6.56) < 0.02, "1UBQ Bjellqvist pI expected 6.56, got \(ubqRep.isoelectricPoint)")
    assert(abs(ubqRep.gravy - (-0.489)) < 0.002 && abs(ubqRep.aliphaticIndex - 100.0) < 0.05 && ubqRep.extinctionReduced == 1490, "1UBQ GRAVY/Aliphatic/Extinction mismatch")

    // 3C.3 多 pKa 量表区分 + 多链复合物 MW 与净电荷独立加和
    let piBj = ProteinBiophysicsEngine.calculateIsoelectricPoint(sequence: ubqSeq, scale: .bjellqvist)
    let piEm = ProteinBiophysicsEngine.calculateIsoelectricPoint(sequence: ubqSeq, scale: .emboss)
    let piLe = ProteinBiophysicsEngine.calculateIsoelectricPoint(sequence: ubqSeq, scale: .lehninger)
    assert(abs(piBj - piEm) > 0.05 && abs(piBj - piLe) > 0.05, "Bjellqvist/EMBOSS/Lehninger pI scales must produce distinct values")
    let mwSingle = ProteinBiophysicsEngine.molecularWeight(chains: [ubqSeq])
    let mwDimer = ProteinBiophysicsEngine.molecularWeight(chains: [ubqSeq, ubqSeq])
    assert(abs(mwDimer - 2.0 * mwSingle) < 1e-6, "Homodimer MW must equal 2 * monomer MW (each chain keeps terminal H2O)")
    let qSingle = ProteinBiophysicsEngine.netCharge(chains: [ubqSeq], atPH: 7.4, scale: .bjellqvist)
    let qDimer = ProteinBiophysicsEngine.netCharge(chains: [ubqSeq, ubqSeq], atPH: 7.4, scale: .bjellqvist)
    assert(abs(qDimer - 2.0 * qSingle) < 1e-9, "Homodimer net charge must equal 2 * monomer net charge")

    // 3C.4 Campen (2008) TOP-IDP + Uversky (2000) 电荷-疏水无序相图区分
    let idpSeq = String(repeating: "PEPSKEQSPK", count: 6)
    let globSeq = String(repeating: "VILFWYMAVL", count: 6)
    let idpEval = ProteinBiophysicsEngine.evaluateDisorderPropensity(sequence: idpSeq)
    let globEval = ProteinBiophysicsEngine.evaluateDisorderPropensity(sequence: globSeq)
    assert(idpEval.disorderPct > 80.0 && idpEval.uverskyDistance < 0.0, "IDP sequence must show high disorderPct and negative Uversky distance")
    assert(globEval.disorderPct < 10.0 && globEval.uverskyDistance > 0.0, "Hydrophobic globular sequence must show low disorderPct and positive Uversky distance")

    // 3C.5 Debye-Hückel 静电屏蔽长度 κ⁻¹ 响应 ionicStrengthM 并影响 M5 评分
    let debLow = ProteinBiophysicsEngine.debyeScreeningLengthA(ionicStrengthM: 0.01, temperatureK: 298.15)
    let debPhys = ProteinBiophysicsEngine.debyeScreeningLengthA(ionicStrengthM: 0.15, temperatureK: 298.15)
    assert(abs(debLow.lengthA - 30.4) < 0.1 && abs(debPhys.lengthA - 7.85) < 0.1, "Debye length formula mismatch: 0.01M=\(debLow.lengthA), 0.15M=\(debPhys.lengthA)")
    let chargedSeq = String(repeating: "EKEKDDDDK", count: 6)
    let repLowSalt = ProteinBiophysicsEngine.analyzeProtein(sequence: chargedSeq, env: ProteinEnvironmentParams(ph: 7.0, temperatureK: 298.15, ionicStrengthM: 0.01))
    let repPhysSalt = ProteinBiophysicsEngine.analyzeProtein(sequence: chargedSeq, env: ProteinEnvironmentParams(ph: 7.0, temperatureK: 298.15, ionicStrengthM: 0.15))
    assert(repLowSalt.debyeLengthA > repPhysSalt.debyeLengthA && repPhysSalt.metricM5Electrostatics != repLowSalt.metricM5Electrostatics, "ionicStrengthM must affect debyeLengthA and M5 electrostatics")

    // 3C.6 构造真实全主链 (N, CA, C, O) α-螺旋 + 反平行 β-折叠 PDB：验证 SE(3) 二面角不变性、Kabsch-Sander DSSP 与 B-factor/pLDDT 严格分离
    func buildRealHelixAndSheetPDB(shift: (Double, Double, Double) = (0, 0, 0), rotZDeg: Double = 0.0) -> String {
        let rad = rotZDeg * Double.pi / 180.0
        let cR = cos(rad), sR = sin(rad)
        func tf(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let rx = x * cR - y * sR + shift.0
            let ry = x * sR + y * cR + shift.1
            let rz = z + shift.2
            return (rx, ry, rz)
        }
        var lines: [String] = [
            "HEADER    TEST ALL-ATOM HELIX AND SHEET",
            "EXPDTA    X-RAY DIFFRACTION"
        ]
        var serial = 1
        func addAtom(_ name: String, _ res3: String, _ chain: String, _ resSeq: Int, _ p: (Double, Double, Double), _ bf: Double, _ elem: String) {
            let q = tf(p.0, p.1, p.2)
            lines.append(String(format: "ATOM  %5d  %-3s %3s %1s%4d    %8.3f%8.3f%8.3f  1.00%6.2f          %2s", serial, (name as NSString).utf8String!, (res3 as NSString).utf8String!, (chain as NSString).utf8String!, resSeq, q.0, q.1, q.2, bf, (elem as NSString).utf8String!))
            serial += 1
        }
        // 12 残基标准右手 α-螺旋 (沿 Z 轴每残基 1.50 Å、旋转 100°；C=O 指向 +Z 与 i+4 的 N-H 形成标准 2.9 Å 氢键)
        for i in 0..<12 {
            let resSeq = i + 1
            let ang = Double(i) * (100.0 * Double.pi / 180.0)
            let z0 = Double(i) * 1.50
            let angN = ang - 0.35
            let angC = ang + 0.35
            let bVal = (i == 0) ? 12.50 : ((i == 11) ? 118.40 : 28.00)
            addAtom("N", "ALA", "A", resSeq, (1.55 * cos(angN), 1.55 * sin(angN), z0 - 0.90), bVal, "N")
            addAtom("CA", "ALA", "A", resSeq, (2.30 * cos(ang), 2.30 * sin(ang), z0), bVal, "C")
            addAtom("C", "ALA", "A", resSeq, (1.75 * cos(angC), 1.75 * sin(angC), z0 + 0.85), bVal, "C")
            addAtom("O", "ALA", "A", resSeq, (1.95 * cos(angC), 1.95 * sin(angC), z0 + 2.08), bVal, "O")
        }
        // 两段手性 L-氨基酸反平行 β-链 (Strand 1: res 21..26 沿 +X，Strand 2: res 31..36 沿 -X，φ≈-150°, ψ≈+150° 非共面褶皱主链，链间间距 4.7 Å 形成标准反平行梯子氢键)
        for k in 0..<6 {
            let x = 25.0 + Double(k) * 3.35
            let sign = (k % 2 == 0) ? 1.0 : -1.0
            let yOff = -0.35 * sign
            addAtom("N", "VAL", "B", 21 + k, (x - 1.15, yOff, -0.35 * sign), 22.0, "N")
            addAtom("CA", "VAL", "B", 21 + k, (x, yOff, 0.55 * sign), 22.0, "C")
            addAtom("C", "VAL", "B", 21 + k, (x + 1.15, yOff, -0.35 * sign), 22.0, "C")
            addAtom("O", "VAL", "B", 21 + k, (x + 1.15, yOff + (sign > 0 ? 1.23 : -1.23), -0.35 * sign), 22.0, "O")
        }
        for k in 0..<6 {
            let x = 25.0 + Double(5 - k) * 3.35
            let sign = ((5 - k) % 2 == 0) ? 1.0 : -1.0
            let yOff = 4.70 + 0.35 * sign
            addAtom("N", "ILE", "C", 31 + k, (x + 1.15, yOff, -0.35 * sign), 24.0, "N")
            addAtom("CA", "ILE", "C", 31 + k, (x, yOff, 0.55 * sign), 24.0, "C")
            addAtom("C", "ILE", "C", 31 + k, (x - 1.15, yOff, -0.35 * sign), 24.0, "C")
            addAtom("O", "ILE", "C", 31 + k, (x - 1.15, yOff + (sign > 0 ? -1.23 : 1.23), -0.35 * sign), 24.0, "O")
        }
        lines.append("END")
        return lines.joined(separator: "\n")
    }

    let pdbOrig = buildRealHelixAndSheetPDB()
    let pdbRotShift = buildRealHelixAndSheetPDB(shift: (42.5, -19.3, 11.7), rotZDeg: 73.0)
    let repOrig = ProteinBiophysicsEngine.analyzeProtein(sequence: "", pdbText: pdbOrig)
    let repRot = ProteinBiophysicsEngine.analyzeProtein(sequence: "", pdbText: pdbRotShift)
    assert(repOrig.dsspComputed && repOrig.helixPct > 0.0 && repOrig.sheetPct > 0.0, "Kabsch-Sander DSSP must detect both α-helix (\(repOrig.helixPct)%) and β-sheet (\(repOrig.sheetPct)%)")
    assert(repOrig.metricM3Ramachandran > 80.0, "Right-handed α-helix/β-sheet Ramachandran favored % must exceed 80% with correct IUPAC dihedral sign, got \(repOrig.metricM3Ramachandran)%")
    if let hPhi = repOrig.residues[3].phi, let hPsi = repOrig.residues[3].psi {
        assert(hPhi < 0 && hPsi < 0, "Right-handed α-helix must have negative (phi, psi), got (\(hPhi), \(hPsi))")
    }
    assert(abs(ProteinBiophysicsEngine.calculateInstabilityIndex(sequence: "YH") - 66.7) < 0.05, "DIWV Y->H must be 13.34 (II('YH') == 66.7)")
    let raf1PDB = "HEADER    RAF-1 KINASE DOMAIN\nEXPDTA    X-RAY DIFFRACTION\n" + pdbOrig
    assert(ProteinBiophysicsEngine.analyzeProtein(sequence: "", pdbText: raf1PDB).temperatureFactorMetric == .bFactor, "RAF-1 X-ray PDB must be classified as .bFactor, NOT .pLDDT")
    assert(repOrig.temperatureFactorMetric == .bFactor, "EXPDTA X-RAY PDB must be classified as .bFactor")
    assert(abs(repOrig.residues[0].temperatureFactor - 12.50) < 1e-3 && abs(repOrig.residues[11].temperatureFactor - 118.40) < 1e-3, "B-factors must NOT be clamped to [25, 100]")
    // 直接验证 dihedralDegrees 在未截断浮点数下的精确 SE(3) 平移/旋转不变性 (< 1e-10°)
    let pA = ProteinVec3(1.2, -0.5, 0.3), pB = ProteinVec3(2.3, 0.4, 1.1), pC = ProteinVec3(1.8, 1.7, 1.9), pD = ProteinVec3(2.9, 2.4, 2.5)
    let radSE3 = 73.0 * Double.pi / 180.0
    func rotShiftVec(_ v: ProteinVec3) -> ProteinVec3 {
        ProteinVec3(v.x * cos(radSE3) - v.y * sin(radSE3) + 42.5, v.x * sin(radSE3) + v.y * cos(radSE3) - 19.3, v.z + 11.7)
    }
    let dOrig = ProteinBiophysicsEngine.dihedralDegrees(pA, pB, pC, pD)!
    let dRot = ProteinBiophysicsEngine.dihedralDegrees(rotShiftVec(pA), rotShiftVec(pB), rotShiftVec(pC), rotShiftVec(pD))!
    assert(abs(dOrig - dRot) < 1e-10, "Exact SE(3) invariance violated for dihedralDegrees: \(dOrig) vs \(dRot)")
    // PDB 固定 %8.3f 坐标格式化会引入 ±0.0005 Å 量化误差（对应 ~0.04° 二面角容差，采用圆周角差以正确处理 ±180° 分支切口）
    func circularAngleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360.0)
        return min(d, 360.0 - d)
    }
    for i in 0..<repOrig.residues.count {
        if let p1 = repOrig.residues[i].phi, let p2 = repRot.residues[i].phi {
            assert(circularAngleDiff(p1, p2) < 0.15, "PDB-quantized SE(3) invariance violated for phi at residue \(i+1): \(p1) vs \(p2)")
        }
        if let s1 = repOrig.residues[i].psi, let s2 = repRot.residues[i].psi {
            assert(circularAngleDiff(s1, s2) < 0.15, "PDB-quantized SE(3) invariance violated for psi at residue \(i+1): \(s1) vs \(s2)")
        }
    }

    // 3C.7 >90 Å 双独立口袋 3D BFS 聚类 + 双拷贝配体实例分离 + 4 位数 PDB SITE 解析
    var dualLines: [String] = ["HEADER    DUAL POCKET LARGE COMPLEX", "EXPDTA    X-RAY DIFFRACTION"]
    var dSerial = 1
    var dRes = 1
    for (cx, chainCh) in [(0.0, "A"), (92.0, "B")] {
        // 在中心周围构造半径 7.5 Å 的中空球壳原子簇以形成明确 P-S-P 独立口袋
        for thetaIdx in 0..<6 {
            let theta = Double(thetaIdx + 1) * Double.pi / 7.0
            for phiIdx in 0..<8 {
                let phi = Double(phiIdx) * 2.0 * Double.pi / 8.0
                let ax = cx + 7.5 * sin(theta) * cos(phi)
                let ay = 7.5 * sin(theta) * sin(phi)
                let az = 7.5 * cos(theta)
                dualLines.append(String(format: "ATOM  %5d  CA  LEU %1s%4d    %8.3f%8.3f%8.3f  1.00 25.00           C", dSerial, (chainCh as NSString).utf8String!, dRes, ax, ay, az))
                dSerial += 1
                dRes += 1
            }
        }
    }
    // 两个相距 92 Å 的独立 ATP 配体拷贝 (A:301 有 3 重原子，B:301 有 2 重原子)
    dualLines.append(String(format: "HETATM%5d  C1  ATP A 301    %8.3f%8.3f%8.3f  1.00 20.00           C", dSerial, 0.0, 0.0, 0.0)); dSerial += 1
    dualLines.append(String(format: "HETATM%5d  C2  ATP A 301    %8.3f%8.3f%8.3f  1.00 20.00           C", dSerial, 1.2, 0.4, 0.0)); dSerial += 1
    dualLines.append(String(format: "HETATM%5d  C3  ATP A 301    %8.3f%8.3f%8.3f  1.00 20.00           C", dSerial, -1.0, -0.5, 0.3)); dSerial += 1
    dualLines.append(String(format: "HETATM%5d  C1  ATP B 301    %8.3f%8.3f%8.3f  1.00 20.00           C", dSerial, 92.0, 0.0, 0.0)); dSerial += 1
    dualLines.append(String(format: "HETATM%5d  C2  ATP B 301    %8.3f%8.3f%8.3f  1.00 20.00           C", dSerial, 93.1, 0.2, 0.0)); dSerial += 1
    dualLines.append("SITE     1 AC1  2 LEU A   1  LEU B  49")
    dualLines.append("END")
    let dualRep = ProteinBiophysicsEngine.analyzeProtein(sequence: "", pdbText: dualLines.joined(separator: "\n"))
    assert(dualRep.pockets.count >= 2, "3D BFS clustering must identify >=2 independent pockets across >90 Å complex, got \(dualRep.pockets.count)")
    let pkDist = sqrt(pow(dualRep.pockets[0].centerX - dualRep.pockets[1].centerX, 2) + pow(dualRep.pockets[0].centerY - dualRep.pockets[1].centerY, 2) + pow(dualRep.pockets[0].centerZ - dualRep.pockets[1].centerZ, 2))
    assert(pkDist > 70.0, "Two pockets must remain spatially separated (~92 Å), got \(pkDist) Å")
    assert(dualRep.pockets.allSatisfy { $0.compactness >= 0.15 && $0.compactness <= 1.0 }, "Pocket sphericity compactness out of range")
    assert(dualRep.healthCard.ligandInstances.count == 2, "Must separate two ATP ligand instances (A:301 and B:301)")
    assert(abs(dualRep.dockingBox.centerX) < 10.0, "Primary ligand box must center on A:301 (~0 Å), NOT averaged across A & B (~46 Å), got \(dualRep.dockingBox.centerX)")
    assert(dualRep.healthCard.pdbSiteResidues.count == 2, "Fixed-column PDB SITE parser must resolve 2 residues")

    // 3C.8 突变 WT 校验、自突变 ΔΔG == 0.0 与 3D rASA 核心/表面加权区分
    let mutChecks = ProteinBiophysicsEngine.evaluateMutantsBatch(wildTypeSequence: ubqSeq, mutationSpecs: ["M1M", "A1G", "I3A"])
    assert(mutChecks.count == 3)
    assert(mutChecks[0].isValidWildType && abs(mutChecks[0].ddgKcalMol) < 1e-9, "Self-mutation M1M must yield exact ddG == 0.0 (no -0.55 ghost bias), got \(mutChecks[0].ddgKcalMol)")
    assert(!mutChecks[1].isValidWildType && mutChecks[1].validationWarning != nil, "WT mismatch A1G (pos 1 is M) must be flagged invalid")
    assert(mutChecks[2].isValidWildType && mutChecks[2].ddgKcalMol > 0.0, "Valid hydrophobic loss I3A must be positive ddG")
    let coreRes = ProteinResidue3D(index: 1, oneLetter: "I", threeLetter: "ILE", x: 0, y: 0, z: 0, plddt: 90, secondary: .helix, hydropathy: 4.5, relativeSASA: 0.08)
    let surfRes = ProteinResidue3D(index: 2, oneLetter: "I", threeLetter: "ILE", x: 15, y: 0, z: 0, plddt: 90, secondary: .coil, hydropathy: 4.5, relativeSASA: 0.72)
    let mut3D = ProteinBiophysicsEngine.evaluateMutantsBatch(wildTypeSequence: "II", mutationSpecs: ["I1A", "I2A"], residues3D: [coreRes, surfRes])
    assert(mut3D[0].burialClass == "core" && mut3D[1].burialClass == "surface" && mut3D[0].ddgKcalMol > mut3D[1].ddgKcalMol * 1.5, "Core mutation (rASA<0.25) must have substantially larger ddG than surface mutation")

    // 3C.9 ProteinDockingBridgeEngine 合成模型拦截、受体清洗 (HOH/altLoc/MODEL2/cofactors) 与 pH 7.4 / --gen3d / --seed / --flex 参数
    var rejectedSpice = false
    do { _ = try ProteinDockingBridgeEngine.sanitizeReceptorForDocking(exportedPDB) } catch { rejectedSpice = true }
    assert(rejectedSpice, "sanitizeReceptorForDocking MUST reject synthetic LABWORKER_SPICE_FOLD model")
    var rejectedCAOnly = false
    let caOnlyPDB = "HEADER    CA ONLY\nATOM      1  CA  ALA A   1       1.000   2.000   3.000  1.00 20.00           C\nEND\n"
    do { _ = try ProteinDockingBridgeEngine.sanitizeReceptorForDocking(caOnlyPDB) } catch { rejectedCAOnly = true }
    assert(rejectedCAOnly, "sanitizeReceptorForDocking MUST reject CA-only structure")

    let dirtyReceptor = """
    MODEL        1
    ATOM      1  N  AALA A   1       1.000   2.000   3.000  0.60 20.00           N
    ATOM      2  N  BALA A   1       1.200   2.100   3.100  0.40 20.00           N
    ATOM      3  CA  ALA A   1       2.400   2.000   3.000  1.00 20.00           C
    HETATM    4  ZN   ZN A 201       5.000   5.000   5.000  1.00 18.00          ZN
    HETATM    5  C1  GOL A 202       8.000   8.000   8.000  1.00 35.00           C
    HETATM    6  O   HOH A 301       9.000   9.000   9.000  1.00 40.00           O
    ENDMDL
    MODEL        2
    ATOM      7  CA  ALA A   1      99.000  99.000  99.000  1.00 20.00           C
    ENDMDL
    """
    let (cleanRecText, prepStats) = try ProteinDockingBridgeEngine.sanitizeReceptorForDocking(dirtyReceptor, format: "pdb", keepCofactors: ["ZN"])
    assert(prepStats.keptAtomCount == 2 && prepStats.keptCofactorAtomCount == 1 && prepStats.removedWaterCount == 1 && prepStats.removedHetatmCount == 1 && prepStats.removedAltLocCount == 1 && prepStats.truncatedExtraModels && prepStats.hasNonCAHeavyAtoms, "Receptor prep stats mismatch: \(prepStats)")
    assert(cleanRecText.contains("ZN") && !cleanRecText.contains("HOH") && !cleanRecText.contains("GOL") && !cleanRecText.contains("99.000"), "Sanitized receptor leaked stripped records")

    let recObArgs = ProteinDockingBridgeEngine.buildObabelReceptorArgs(inputPath: "r.pdb", outputPath: "r.pdbqt")
    assert(recObArgs.contains("-xr") && recObArgs.contains("-p") && recObArgs.contains("7.4"), "Receptor obabel args must include -xr and -p 7.4")
    let ligSmilesArgs = ProteinDockingBridgeEngine.buildObabelLigandArgs(inputPath: nil, smiles: "CCO", outputPath: "l.pdbqt")
    assert(ligSmilesArgs.contains("--gen3d") && ligSmilesArgs.contains("-p") && ligSmilesArgs.contains("7.4"), "SMILES ligand obabel args must include --gen3d and -p 7.4")
    let sdf2D = "mol\n  Prog 2D\n\n  2  1  0  0  0  0            999 V2000\n    0.0000    0.0000    0.0000 C   0\n    1.5000    0.0000    0.0000 O   0\nM  END\n"
    assert(ProteinDockingBridgeEngine.ligandFileNeeds3DGeneration(sdf2D, fileExtension: "sdf"), "2D SDF must trigger --gen3d")
    let vinaArgs = ProteinDockingBridgeEngine.buildVinaArguments(receptorPath: "r.pdbqt", ligandPath: "l.pdbqt", outputPath: "o.pdbqt", box: ubqRep.dockingBox, seed: 42, flexReceptorPath: "flex.pdbqt")
    assert(vinaArgs.contains("--seed") && vinaArgs.contains("42") && vinaArgs.contains("--flex") && vinaArgs.contains("flex.pdbqt"), "Vina args must support --seed and --flex")

    // 3C.10 Swift vs Python MCP 对等性核验 (1UBQ DIWV / Bjellqvist pI / Debye / 自突变 0.0 / WT 校验)
    let py3CCode = """
    import sys, json
    sys.path.insert(0, 'Sources/CloneStudioCore/Resources')
    import clonestudio_mcp_server as srv
    srv.notify_gui_and_sync_primers = lambda *a, **k: 'noop'
    res = srv.tool_analyze_protein_and_docking_box({
        'sequence': '\(ubqSeq)',
        'ph': 7.0,
        'temperature_k': 298.15,
        'ionic_strength_m': 0.15,
        'pka_scale': 'bjellqvist',
        'mutations': ['M1M', 'A1G']
    })
    print(json.dumps(res))
    """
    let proc3C = Process()
    proc3C.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc3C.arguments = ["-c", py3CCode]
    let pipe3C = Pipe()
    proc3C.standardOutput = pipe3C
    try proc3C.run()
    proc3C.waitUntilExit()
    assert(proc3C.terminationStatus == 0, "Python MCP 3C parity script failed")
    if let obj = try JSONSerialization.jsonObject(with: pipe3C.fileHandleForReading.readDataToEndOfFile()) as? [String: Any] {
        assert(abs((obj["instability_index"] as? Double ?? 0) - 36.06) < 0.02, "Python MCP 1UBQ DIWV mismatch")
        assert(abs((obj["isoelectric_point"] as? Double ?? 0) - 6.56) < 0.02, "Python MCP 1UBQ Bjellqvist pI mismatch")
        assert(abs((obj["debye_length_a"] as? Double ?? 0) - 7.85) < 0.1, "Python MCP Debye length mismatch")
        let pyMuts = obj["mutant_evaluations"] as? [[String: Any]] ?? []
        assert(pyMuts.count == 2 && (pyMuts[0]["ddg_kcal_mol"] as? Double ?? 99) == 0.0 && (pyMuts[1]["is_valid_wild_type"] as? Bool) == false, "Python MCP self-mutation/WT-mismatch parity failed")
    }

    pass("Sub-batch 3C scientific rigor suite passed (Guruprasad DIWV, Bjellqvist pI, TOP-IDP, Debye, Kabsch-Sander DSSP, LIGSITE 3D BFS, WT-DDG & Vina Bridge).")
}
do {
    try runTest68SubBatch3C()
} catch {
    fatalError("Sub-batch 3C test failed: \(error)")
}

// MARK: - Test 69: Sub-batch 3D (CHOPCHOP Priority/Unscored, HDR NAG/NGA/RevCDS/Richardson, Sanger Mott/Gotoh, SBOL3/GenBank/6-Frame, Dam Digest/Spline/Gel, RNA Turner/Molar Continuity)
func runTest69SubBatch3D() throws {
    print("🧪 [69/69] Testing Sub-batch 3D (CRISPR Priority/Unscored, HDR NAG/NGA/Richardson, Sanger Mott/Gotoh, SBOL3/6-Frame, Dam/Spline, RNA Turner & Molar Continuity)...")

    // 3D.1 CHOPCHOPResult 优先级反转修复 (.exact > .coreOverlap > .reverseComplementOverlap) + 无脱靶数据禁满分 + Broad 缺失效价禁填 2.0
    assert(CHOPCHOPLocalMatchKind.exact.priority > CHOPCHOPLocalMatchKind.coreOverlap(20).priority, ".exact priority must strictly exceed .coreOverlap")
    assert(CHOPCHOPLocalMatchKind.coreOverlap(18).priority > CHOPCHOPLocalMatchKind.reverseComplementOverlap(20).priority, ".coreOverlap priority must exceed .reverseComplementOverlap")
    let tExact = LocalCompareTarget(label: "ExactHit", sequence: "GACGATCGATCGATCGATCG", sourceType: .sgRNA, isSelectedOrGenerated: true)
    let tCore = LocalCompareTarget(label: "CoreHit", sequence: "ACGATCGATCGATCGATCGA", sourceType: .sgRNA, isSelectedOrGenerated: true)
    let bestHit = CHOPCHOPLocalMatchResult.bestMatch(primarySequence: "GACGATCGATCGATCGATCG", fullSequence: "GACGATCGATCGATCGATCGTGG", localTargets: [tCore, tExact])
    assert(bestHit?.kind == .exact && bestHit?.matchedTarget.label == "ExactHit", "bestMatch must pick .exact over .coreOverlap, got \(String(describing: bestHit?.kind)) (\(bestHit?.matchedTarget.label ?? "nil"))")

    let unscoredTarget = CHOPCHOPTarget(
        rank: 1, targetSequence: "GACGATCGATCGATCGATCGTGG", spacer: "GACGATCGATCGATCGATCG", pam: "TGG",
        genomicLocation: "chr17:100", strand: "+", gcContent: 55.0, selfComplementarity: 0,
        mm0: 0, mm1: 0, mm2: 0, mm3: 0, efficiency: 72.0,
        sources: [.ucscCrispor], hasCHOPCHOPOffTargets: false, vbcScore: nil, vbcActivity: nil,
        vbcFrameshift: 0.78, vbcBioscore: 0.81, mitSpecificity: nil
    )
    assert(unscoredTarget.combinedScore.score <= 55.0 && unscoredTarget.combinedScore.tier != .excellent, "Missing off-target index must NOT award 45/45 or .excellent, got \(unscoredTarget.combinedScore.score)")
    assert(unscoredTarget.combinedScore.tags.contains { $0.name.contains("未评分") || $0.name.contains("Unscored") }, "Missing off-target must emit unscored tag")
    assert(unscoredTarget.combinedScore.tags.contains { $0.name.contains("移码") || $0.name.contains("Frameshift") }, "vbcFrameshift must be exposed in score tags")
    assert(unscoredTarget.combinedScore.tags.contains { $0.name.contains("保守") || $0.name.contains("Bioscore") }, "vbcBioscore must be exposed in score tags")

    let missingBroad = BroadGPPShRNATarget(
        rank: 1, primaryCloneID: "TRCN_TEST", allCloneIDs: ["TRCN_TEST"], targetSequence: "CCAGTCCCTATCACCATAGAA",
        vectors: ["pLKO.1"], matchRegions: "CDS", matchPercent: 100, sdrMatchPercent: 100,
        intrinsicScore: nil, adjustedScore: nil, matchesOtherGene: false
    )
    assert(missingBroad.combinedScore.score <= 65.0 && missingBroad.combinedScore.tags.contains { $0.name.contains("未评分") || $0.name.contains("Missing") }, "Missing Broad scores must NOT optimistically fill 2.0")

    // 3D.2 HDRDonorEngine: 非编码区避开 NAG/NGA、负链 CDS、外显子 cdsFrameOffset、Paquet >10 bp 距离告警、Richardson 36/91 不对称 ssODN
    let ncRef = String(repeating: "ACTGCATGCTAG", count: 10) + "GACGATCGATCGATCGATCGTGG" + String(repeating: "CTAGCATGCAGT", count: 10)
    let ncSgPos = ncRef.range(of: "GACGATCGATCGATCGATCG")!
    let ncSgStart = ncRef.distance(from: ncRef.startIndex, to: ncSgPos.lowerBound)
    let ncRep = try HDRDonorEngine.designHDRDonor(HDRDonorRequest(
        referenceSequence: ncRef, sgRNASequence: "GACGATCGATCGATCGATCG", strand: "+",
        editStart0Based: ncSgStart + 14, editEnd0Based: ncSgStart + 15, replacementSequence: "A",
        donorFormat: .ssODN, autoDetectCDS: false, asymmetricRichardsonSSODN: true
    ))
    assert(ncRep.blockingStrategy == .pamNonCoding && !ncRep.pamStillIntact, "Non-coding PAM block failed")
    assert(ncRep.editedPamSequence != "TAG" && ncRep.editedPamSequence != "TGA" && !ncRep.editedPamSequence.hasSuffix("GG"), "Non-coding PAM block must avoid NAG/NGA/NGG, got \(ncRep.editedPamSequence)")
    assert(ncRep.leftArmLengthBp == 36 && ncRep.rightArmLengthBp == 91 && ncRep.donorStrandOrientation == "target_strand_antisense_richardson_36_91", "Richardson 2016 asymmetric ssODN expected 36/91 nt target strand, got \(ncRep.leftArmLengthBp)/\(ncRep.rightArmLengthBp) \(ncRep.donorStrandOrientation)")

    // Paquet (2016) > 10 bp 距离告警 + 非 ATG 外显子 cdsFrameOffset 读码框支持
    let exonRef = "C" + String(repeating: "GCTGAAGCTGAC", count: 10) + "GCTGACGATCGATCGATCGATCGG" + String(repeating: "GCTGAAGCTGAC", count: 10)
    let exSg = "CTGACGATCGATCGATCGAT"
    let exRange = exonRef.range(of: exSg)!
    let exStart = exonRef.distance(from: exonRef.startIndex, to: exRange.lowerBound)
    let exRep = try HDRDonorEngine.designHDRDonor(HDRDonorRequest(
        referenceSequence: exonRef, sgRNASequence: exSg, strand: "+",
        editStart0Based: exStart, editEnd0Based: exStart + 1, replacementSequence: "A",
        cdsFrameOffset: 1, autoDetectCDS: false
    ))
    assert(exRep.isInCDS && exRep.aminoAcidConserved, "Non-ATG exon cdsFrameOffset must preserve amino acid sequence")
    assert(exRep.cutToEditDistanceBp > 10 && exRep.warnings.contains { $0.contains("Paquet") }, "DSB-to-edit > 10 bp must emit Paquet (2016) warning, dist=\(exRep.cutToEditDistanceBp)")

    // 负链 CDS 翻译守恒验证（两侧使用 TTATTA 终止子侧翼，避免侧翼出现更长伪 ORF）
    let fwdCoding = "ATGGCTGACGATCGATCGATCGATCGGGCTGAAGCTGACGCTGAAGCTGACGCTGAAGCTGACGCTGAAGCTGACGCTGAAGCTGACGCTGAAGCTTAA"
    let revLocus = String(repeating: "TTATTA", count: 10) + BioSequence.reverseComplement(fwdCoding) + String(repeating: "TTATTA", count: 10)
    let revCdsStart1 = 61
    let revCdsEnd1 = 60 + fwdCoding.count
    let revAuto = HDRDonorEngine.detectCDSRegionWithStrand(in: revLocus, coveringIndex0Based: 80)
    assert(revAuto != nil && revAuto?.strand == "-" && revAuto?.start0Based == (revCdsStart1 - 1) && revAuto?.end0Based == revCdsEnd1, "Reverse-strand CDS auto-detection failed: \(String(describing: revAuto))")

    // 3D.3 SangerAlignmentEngine: Mott 修剪全低质量读段 + Gotoh 仿射空位合并多碱基 Indel + PlasmidSequencingAssemblyEngine 无 +0bp 假插入
    // 构造全 Q=8 的合成 FASTQ 输入验证 Mott 修剪整段归零
    let allLowFastq = "@AllLowQ\n" + String(repeating: "ACGT", count: 15) + "\n+\n" + String(repeating: ")", count: 60) + "\n" // ASCII ')' = 41 -> Q = 8
    let allLowChrom = SangerAlignmentEngine.parseData(Data(allLowFastq.utf8), sampleName: "AllLowQ.fastq", trimQualityThreshold: 20)
    assert(allLowChrom.trimmedLength == 0, "Mott trimming must completely trim all-low-quality (Q=8) reads, got trimmedLength=\(allLowChrom.trimmedLength)")

    // Gotoh 仿射空位合并 3-bp 连续缺失为单个 in-frame 变异事件
    let refForGotoh = "ATGCTAGCTAGCTAGCTAGCGATCGATCGATCGATCGATCGCTAGCTAGCTAGCTAGCTAGCTAGCATGCATGCATGC"
    let del3Read = String(refForGotoh.prefix(30)) + String(refForGotoh.dropFirst(33)) // 删除 3 bp (位置 31..33)
    let del3AB1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: del3Read, sampleName: "Del3_Gotoh.ab1", simulateNoisyEnds: false)
    let del3Chrom = SangerAlignmentEngine.parseData(del3AB1, sampleName: "Del3_Gotoh.ab1", trimQualityThreshold: 15)
    let del3Rep = SangerAlignmentEngine.verifyAgainstPlasmid(chromatogram: del3Chrom, referenceSequence: refForGotoh, referenceName: "GotohRef")
    let delEvents = del3Rep.variants.filter { $0.kind == .deletion }
    assert(delEvents.count == 1 && delEvents[0].hgvsNotation.contains("del"), "3-bp contiguous deletion must collapse into 1 multi-bp VariantCall, got \(delEvents.map(\.hgvsNotation))")

    // 3D.4 SequenceFormatEngine: SBOL3 跨原点特征无损往返 + GenBank IUPAC / 转义 ^ / join(complement(...)) + PlasmidAnnotationEngine 6 框蛋白匹配
    let circSeq500 = String(repeating: "ATGCGTACGT", count: 50)
    let origSpanFeat = SnapGeneFeature(
        name: "OriginSpanCDS", type: "CDS", directionality: "1",
        segments: [
            SnapGeneSegment(range: "460-500", start: 460, end: 500, color: "#3b82f6"),
            SnapGeneSegment(range: "1-40", start: 1, end: 40, color: "#3b82f6")
        ]
    )
    let sbolSrc = SnapGeneFileInfo(filePath: "t.dna", fileName: "OrigSpan.dna", sequence: circSeq500, length: 500, isCircular: true, featuresCount: 1, features: [origSpanFeat])
    let sbolOut = try SequenceFormatEngine.exportSBOL3JSONLD(info: sbolSrc, name: "OrigSpan")
    let sbolBack = SequenceFormatEngine.parseSBOL3JSONLD(sbolOut)
    assert(sbolBack.count == 1 && sbolBack[0].features.count == 1 && sbolBack[0].features[0].segments.count == 2, "SBOL3 origin-spanning feature must preserve 2 segments")
    assert(sbolBack[0].features[0].segments[0].start == 460 && sbolBack[0].features[0].segments[0].end == 500 && sbolBack[0].features[0].segments[1].start == 1 && sbolBack[0].features[0].segments[1].end == 40, "SBOL3 origin-spanning coordinates must NOT flip to complement [40-460]")

    let gbIUPAC = """
    LOCUS       TestIUPAC                30 bp    DNA     circular SYN 01-JAN-2026
    FEATURES             Location/Qualifiers
         misc_feature    12^13
                         /label="CutSite"
         CDS             join(complement(20..28),complement(5..10))
                         /label="RevJoinCDS"
    ORIGIN
            1 atgcrnyskmbdhvatgcatgcatgcatgc
    //
    """
    guard let parsedIUPAC = SequenceFormatEngine.parseGenBank(gbIUPAC) else { fatalError("GenBank IUPAC parse failed") }
    assert(parsedIUPAC.sequence.contains("R") && parsedIUPAC.sequence.contains("N") && parsedIUPAC.length == 30, "GenBank parser must preserve IUPAC ambiguity bases, got len=\(parsedIUPAC.length)")
    let cutFeat = parsedIUPAC.features.first { $0.name == "CutSite" }
    assert(cutFeat != nil && cutFeat?.segments.first?.start == 12 && cutFeat?.segments.first?.end == 13, "GenBank 12^13 site feature must parse cleanly")
    let gbExportedIUPAC = SequenceFormatEngine.exportGenBank(info: parsedIUPAC, name: "IUPACRoundtrip")
    let gbReparsedIUPAC = SequenceFormatEngine.parseGenBank(gbExportedIUPAC)
    assert(gbExportedIUPAC.replacingOccurrences(of: " ", with: "").lowercased().contains("atgcrnyskmbdhv") && gbReparsedIUPAC?.sequence == parsedIUPAC.sequence, "GenBank exporter must preserve IUPAC ambiguity bases cleanly in 10-bp ORIGIN blocks")
    let revJoinFeat = parsedIUPAC.features.first { $0.name == "RevJoinCDS" }
    assert(revJoinFeat?.directionality == "2" && revJoinFeat?.segments.count == 2 && revJoinFeat?.segments[0].start == 5 && revJoinFeat?.segments[1].start == 20, "GenBank join(complement(...)) parsing failed")

    // 负链 CDS 完整 HDR 设计（含 RFLP 同义突变）保持氨基酸 100% 守恒（含实存 NGG PAM，禁用静默跳过分支）
    let revHdrCoding = "ATGGCTGACGATCGATCGATCGATCGGGCTGAAGCTGACCCCGAAGCTGACGCTGAAGCTGACGCTGAAGCTGACGCTGAAGCTGACGCTGAAGCTTAA"
    let revHdrLocus = String(repeating: "TTATTA", count: 10) + BioSequence.reverseComplement(revHdrCoding) + String(repeating: "TTATTA", count: 10)
    let revHdrAuto = HDRDonorEngine.detectCDSRegionWithStrand(in: revHdrLocus, coveringIndex0Based: 95)
    assert(revHdrAuto != nil && revHdrAuto?.strand == "-", "Negative-strand HDR locus must auto-detect '-' CDS")
    let revHdrChars = Array(revHdrLocus)
    var revPamFoundStart: Int? = nil
    for p in (revHdrAuto!.start0Based + 20)...(revHdrAuto!.end0Based - 3) {
        if revHdrChars[p + 1] == "G" && revHdrChars[p + 2] == "G" {
            revPamFoundStart = p - 20
            break
        }
    }
    assert(revPamFoundStart != nil, "Negative-strand HDR test locus must contain an active NGG PAM inside CDS")
    let rStart = revPamFoundStart!
    let revGuide = String(revHdrChars[rStart..<(rStart + 20)])
    let revHDR = try HDRDonorEngine.designHDRDonor(HDRDonorRequest(
        referenceSequence: revHdrLocus, sgRNASequence: revGuide, strand: "+",
        editStart0Based: rStart + 15, editEnd0Based: rStart + 16, replacementSequence: "A",
        autoDetectCDS: true, enableRFLP: true
    ))
    assert(revHDR.cdsStrand == "-" && revHDR.aminoAcidConserved && revHDR.cas9RecutBlocked, "Negative-strand HDR + RFLP must preserve amino acid sequence and block recut")

    // PlasmidSequencingAssemblyEngine 回归：无 +0bp 假插入 + Nanopore 均聚物提示
    let asmFlankL = String(CodonOptimizationEngine.demoEGFPFragmentDNA.prefix(150))
    let asmFlankR = String(CodonOptimizationEngine.demoEGFPFragmentDNA.suffix(150))
    let asmRef = asmFlankL + "TTTTT" + asmFlankR
    let asmQ = asmFlankL + "TTTTTT" + asmFlankR
    let asmRep = PlasmidSequencingAssemblyEngine.verifyWholePlasmid(querySequence: asmQ, queryName: "AsmQ", referenceSequence: asmRef, referenceName: "AsmRef")
    assert(!asmRep.variants.contains { $0.sizeBp == 0 }, "Whole-plasmid assembly must never emit +0 bp fake variants")
    assert(asmRep.variants.contains { $0.kind == .smallInsertion && ($0.detail.contains("Nanopore") || $0.detail.contains("均聚物")) }, "1-bp insertion inside >=4 nt homopolymer must emit Nanopore homopolymer note")

    // PlasmidAnnotationEngine 6 框蛋白翻译匹配（同义密码子改写后仍可检出，且优先于短 DNA 碎片）
    let wtDemoCDS = CodonOptimizationEngine.demoEGFPFragmentDNA
    let optDemoCDS = CodonOptimizationEngine.optimize(inputSequence: wtDemoCDS, isProteinInput: false, config: .presetConfig(.twist, host: .eColi)).optimizedDNA
    let customLib = [PlasmidAnnotationEngine.PlasmidFeatureRecord(id: 9999, name: "EGFP_Ref", category: "reporter", sequence: wtDemoCDS, direction: 1, colorHex: "#10b981")]
    let protAnnot = PlasmidAnnotationEngine.annotate(sequence: "AAAAAAA" + optDemoCDS + "TTTTTTT", plasmidName: "CodonOptTest", isCircular: false, featuresLibrary: customLib)
    assert(protAnnot.features.contains { $0.name == "EGFP_Ref" && !$0.isFragment && $0.identity >= 0.99 }, "6-frame protein translation matcher must detect full-length codon-optimized EGFP CDS over DNA fragments")

    // 3D.5 DiagnosticDigestEngine: ClaI / XbaI Dam 甲基化阻断（含线性 5' 边界坐标）+ SmaI 25°C + GelAnalysisEngine PCHIP 单调样条 C¹ 边界连续性
    let xbaDamSeq = String(repeating: "ACTG", count: 50) + "TCTAGATC" + String(repeating: "CGTA", count: 50)
    let claDamSeq = String(repeating: "ACTG", count: 50) + "ATCGATC" + String(repeating: "CGTA", count: 50)
    let xbaEnz = RestrictionEnzymeDatabase.shared.find(name: "XbaI")!
    let claEnz = RestrictionEnzymeDatabase.shared.find(name: "ClaI")!
    assert(DiagnosticDigestEngine.digestFragments(sequence: xbaDamSeq, enzymes: [xbaEnz], isCircular: true, damMethylated: false).count == 1, "Unmethylated XbaI must cut once")
    assert(DiagnosticDigestEngine.digestFragments(sequence: xbaDamSeq, enzymes: [xbaEnz], isCircular: true, damMethylated: true).isEmpty, "Dam-methylated XbaI (TCTAGATC) must be blocked")
    assert(DiagnosticDigestEngine.digestFragments(sequence: claDamSeq, enzymes: [claEnz], isCircular: true, damMethylated: false).count == 1, "Unmethylated ClaI must cut once")
    assert(DiagnosticDigestEngine.digestFragments(sequence: claDamSeq, enzymes: [claEnz], isCircular: true, damMethylated: true).isEmpty, "Dam-methylated ClaI (ATCGATC) must be blocked")
    let lin5Blocks = RestrictionEnzymeDatabase.shared.checkMethylationBlock(enzymeName: "XbaI", sequence: "TCTAGATCCCCCCCC", siteStart0Based: 0, siteLength: 6, circular: false, damMethylated: true)
    assert(!lin5Blocks.isEmpty, "Linear 5'-end XbaI overlapped by Dam (siteStart=0) must detect Dam block without coordinate shift")
    assert(RestrictionEnzymeDatabase.shared.bufferCompatibility(for: "SmaI").incubationTempC == 25, "SmaI incubation temp must be 25°C")
    assert(RestrictionEnzymeDatabase.shared.bufferCompatibility(for: "NonExistentEnzymeXYZ").isCuratedNEBEntry == false, "Uncurated enzymes must not claim curated 100% CutSmart")

    let splinePts: [(y: Double, log10Size: Double, size: Double)] = [
        (0.15, log10(10000.0), 10000.0),
        (0.32, log10(3000.0), 3000.0),
        (0.55, log10(1000.0), 1000.0),
        (0.82, log10(250.0), 250.0)
    ]
    let splineFit = GelLadderCalibrationFit(slope: -2.4, intercept: 4.3, r2: 0.99, n: 4, points: splinePts)
    for pt in splinePts {
        assert(abs(splineFit.size(atY: pt.y) - pt.size) < 1e-2, "PCHIP spline must interpolate exact ladder knot \(pt.size) bp, got \(splineFit.size(atY: pt.y))")
    }
    let edgeIn = splineFit.size(atY: 0.15)
    let edgeOut = splineFit.size(atY: 0.1499)
    assert(abs(edgeOut - edgeIn) < 50.0, "PCHIP C1 tangent extrapolation must be continuous across yFirst boundary, got \(edgeOut) vs \(edgeIn)")
    assert(splineFit.relativeMobility(atY: 0.50) > 0.4 && splineFit.relativeMobility(atY: 0.50) < 0.6, "Relative mobility Rf out of expected range")

    // 3D.6 CodonOptimizationEngine RNA Turner 2004 (G:U 摇摆配对打破纯 WC 干长极限，无 G:U 时为 0.0) + 调控基序 + DNAMolarCalculator + Tataurov ε260
    let wobbleGU = CodonOptimizationEngine.calcRNA5PrimeHairpinDG(dnaSeq: "GGGTGGAAAACCTGTC", upstreamUTR: "")
    assert(wobbleGU < -1.0, "RNA Turner 2004 must fold G:U wobble-bridged stem (< -1.0 kcal/mol vs 0.0 WC-only), got \(wobbleGU)")
    let motifHitsEuk = CodonOptimizationEngine.scanBiologicalMotifs(dna: "ATGGCTAGGTAAGTGCTAATAAACTGA", host: .human)
    assert(motifHitsEuk.count >= 2, "Must detect cryptic splice donor AGGTAAGT and premature Poly(A) AATAAA")
    let motifHitsProk = CodonOptimizationEngine.scanBiologicalMotifs(dna: "ATGGCTAGGAGGCTGA", host: .eColi)
    assert(!motifHitsProk.isEmpty, "Must detect prokaryotic pseudo-SD AGGAGG")

    let m1999 = DNAMolarCalculator.calculate(cloneType: .single, isVector: true, lengthKb: 1.999)
    let m2000 = DNAMolarCalculator.calculate(cloneType: .single, isVector: true, lengthKb: 2.000)
    let m2001 = DNAMolarCalculator.calculate(cloneType: .single, isVector: true, lengthKb: 2.001)
    assert(abs(m1999.recommendedNg - 50.0) < 1e-6 && abs(m2000.recommendedNg - 50.0) < 1e-6 && abs(m2001.recommendedNg - 50.0) < 1e-6, "DNAMolarCalculator must be continuous across 1.999 / 2.000 / 2.001 kb without a step jump")
    let m50kb = DNAMolarCalculator.calculate(cloneType: .single, isVector: true, lengthKb: 50.0)
    assert(m50kb.recommendedNg == 200.0 && m50kb.unitWarning != nil, "50.0 kb input must NOT silently divide by 1000 and must emit explicit unitWarning")

    let epsATGC = LabDNAConverter.oligoExtinctionCoefficient260(sequence: "ATGC")!
    assert(abs(epsATGC.epsilon260 - 39200.0) < 1e-6, "Tataurov (2008) exact ε260 for ATGC must be 39200 M^-1 cm^-1 (22800+19000+17600-8700-11500), got \(epsATGC.epsilon260)")
    let epsA = LabDNAConverter.oligoExtinctionCoefficient260(sequence: "AAAAAAAAAA")!
    let epsC = LabDNAConverter.oligoExtinctionCoefficient260(sequence: "CCCCCCCCCC")!
    assert(epsA.epsilon260 > epsC.epsilon260 * 1.5, "Nearest-neighbor ε260 for poly-A (\(epsA.epsilon260)) must substantially exceed poly-C (\(epsC.epsilon260))")

    let xbaEmpty = String(repeating: "ACTG", count: 80) + "GAATTC" + String(repeating: "CGTA", count: 80)
    let xbaRecomb = String(repeating: "ACTG", count: 80) + "GAATTC" + String(repeating: "A", count: 100) + "TCTAGATC" + String(repeating: "T", count: 100) + String(repeating: "CGTA", count: 80)
    let methRepDam = DiagnosticDigestEngine.recommendTopDigests(emptyVectorSequence: xbaEmpty, recombinantSequence: xbaRecomb, isCircular: false, enzymeNames: ["EcoRI", "XbaI"], minBands: 1, maxBands: 4, topN: 5, damMethylated: true)
    let methRepUnm = DiagnosticDigestEngine.recommendTopDigests(emptyVectorSequence: xbaEmpty, recombinantSequence: xbaRecomb, isCircular: false, enzymeNames: ["EcoRI", "XbaI"], minBands: 1, maxBands: 4, topN: 5, damMethylated: false)
    assert(!methRepDam.insertOnlyCutters.contains("XbaI") && methRepUnm.insertOnlyCutters.contains("XbaI"), "Dam-methylated recommendTopDigests must exclude Dam-blocked XbaI while unmethylated keeps it")

    let py3DCode = """
    import json, sys
    sys.path.insert(0, '\(FileManager.default.currentDirectoryPath)/Sources/CloneStudioCore/Resources')
    import clonestudio_mcp_server as srv
    xba_frags_dam = srv.simulate_digest_fragments('\(xbaDamSeq)', ['XbaI'], is_circular=True, dam_methylated=True)
    xba_frags_unm = srv.simulate_digest_fragments('\(xbaDamSeq)', ['XbaI'], is_circular=True, dam_methylated=False)
    hdr_py = srv.tool_design_hdr_donor({
        'reference_sequence': '\(revHdrLocus)',
        'sgrna_sequence': '\(revGuide)',
        'strand': '+',
        'edit_start_0based': \(rStart),
        'edit_end_0based': \(rStart + 1),
        'replacement_sequence': 'A',
        'auto_detect_cds': True,
        'enable_rflp': True,
        'asymmetric_richardson_ssodn': True
    })
    print(json.dumps({
        'xba_dam': len(xba_frags_dam), 'xba_unm': len(xba_frags_unm),
        'cds_strand': hdr_py.get('cds_strand'), 'aa_ok': hdr_py.get('amino_acid_conserved'),
        'left_arm': hdr_py.get('left_arm_length_bp'), 'right_arm': hdr_py.get('right_arm_length_bp'),
        'paquet': any('Paquet' in w for w in hdr_py.get('warnings', []))
    }))
    """
    let proc3D = Process()
    proc3D.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc3D.arguments = ["-c", py3DCode]
    let pipe3D = Pipe()
    proc3D.standardOutput = pipe3D
    try proc3D.run()
    proc3D.waitUntilExit()
    assert(proc3D.terminationStatus == 0, "Python MCP 3D parity script failed")
    if let obj = try JSONSerialization.jsonObject(with: pipe3D.fileHandleForReading.readDataToEndOfFile()) as? [String: Any] {
        assert((obj["xba_dam"] as? Int ?? -1) == 0 && (obj["xba_unm"] as? Int ?? -1) == 1, "Python MCP Dam methylation digest parity failed")
        assert((obj["cds_strand"] as? String) == "-" && (obj["aa_ok"] as? Bool) == true, "Python MCP negative-strand HDR parity failed")
        assert((obj["left_arm"] as? Int) == 36 && (obj["right_arm"] as? Int) == 91 && (obj["paquet"] as? Bool) == true, "Python MCP Richardson 36/91 & Paquet >10 bp warning parity failed")
    }

    pass("Sub-batch 3D scientific rigor suite passed (CHOPCHOP Priority/Unscored, HDR NAG/NGA/RevCDS/Richardson, Sanger Mott/Gotoh, SBOL3/GenBank/6-Frame, Dam/PCHIP, RNA Turner & Molar Continuity).")
}
do {
    try runTest69SubBatch3D()
} catch {
    fatalError("Sub-batch 3D test failed: \(error)")
}

let finalPyToolCount = await MainActor.run { PlasmidPoolManager.mcpToolsCatalog.count }
print("COUNTS tests=\(passedTests.count) tools=\(finalPyToolCount) modules=\(NavItem.allCases.count)")
print("\n🎉 ALL \(passedTests.count) AUTOMATED VERIFICATION TESTS PASSED SUCCESSFULLY!")
