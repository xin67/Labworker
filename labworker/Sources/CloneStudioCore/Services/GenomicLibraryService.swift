import Foundation
import SQLite3

/// 全基因组 sgRNA 与 shRNA 本地数据库查询引擎 (基于 macOS 原生 SQLite3，<5ms 极速检索)
public final class GenomicLibraryService {
    public static let shared = GenomicLibraryService()
    
    private var db: OpaquePointer? = nil
    
    public init() {
        openDatabase()
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    /// 定位并打开 SQLite 数据库
    private func openDatabase() {
        guard let dbPath = CloneStudioResourceLocator.path(forResource: "Libraries", ofType: "sqlite") else {
            print("⚠️ 未找到 Libraries.sqlite 数据库文件")
            return
        }
        
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            print("⚠️ 打开 Libraries.sqlite 失败: \(String(cString: sqlite3_errmsg(db)))")
            db = nil
        }
    }
    
    /// 执行检索
    /// - Parameters:
    ///   - query: 基因名称关键词（如 TP53, Trp53, PRKAA1 等）
    ///   - species: 人源 (human) 或 鼠源 (mouse)
    ///   - type: sgRNA 或 shRNA
    ///   - limit: 最大返回条数
    public func search(
        query: String,
        species: TargetSpecies,
        type: GenomicTargetType,
        limit: Int = 100
    ) -> [GenomicTarget] {
        guard let db = db else { return [] }
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        let cleanQuery = trimmed.uppercased()
        let tableName = (type == .sgRNA) ? "sgrna" : "shrna"
        
        // 跨物种同源基因智能别名转换（如人鼠 p53: TP53 <-> TRP53）
        var aliasQuery: String? = nil
        if species == .mouse && cleanQuery == "TP53" {
            aliasQuery = "TRP53"
        } else if species == .human && cleanQuery == "TRP53" {
            aliasQuery = "TP53"
        }
        
        let sql: String
        if aliasQuery != nil {
            sql = """
            SELECT id, gene, seq FROM \(tableName)
            WHERE species = ? AND (gene_upper = ? OR gene_upper = ? OR gene_upper LIKE ? OR gene_upper LIKE ?)
            ORDER BY 
                CASE 
                    WHEN gene_upper = ? OR gene_upper = ? THEN 1
                    WHEN gene_upper LIKE ? THEN 2
                    ELSE 3
                END, id ASC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT id, gene, seq FROM \(tableName)
            WHERE species = ? AND (gene_upper = ? OR gene_upper LIKE ? OR gene_upper LIKE ?)
            ORDER BY 
                CASE 
                    WHEN gene_upper = ? THEN 1
                    WHEN gene_upper LIKE ? THEN 2
                    ELSE 3
                END, id ASC
            LIMIT ?;
            """
        }
        
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        
        var paramIdx: Int32 = 1
        // 绑定 species
        sqlite3_bind_text(stmt, paramIdx, (species.rawValue as NSString).utf8String, -1, nil); paramIdx += 1
        
        let prefixPattern = "\(cleanQuery)%"
        let containsPattern = "%\(cleanQuery)%"
        
        if let alias = aliasQuery {
            sqlite3_bind_text(stmt, paramIdx, (cleanQuery as NSString).utf8String, -1, nil); paramIdx += 1
            sqlite3_bind_text(stmt, paramIdx, (alias as NSString).utf8String, -1, nil); paramIdx += 1
            sqlite3_bind_text(stmt, paramIdx, (prefixPattern as NSString).utf8String, -1, nil); paramIdx += 1
            sqlite3_bind_text(stmt, paramIdx, (containsPattern as NSString).utf8String, -1, nil); paramIdx += 1
            
            sqlite3_bind_text(stmt, paramIdx, (cleanQuery as NSString).utf8String, -1, nil); paramIdx += 1
            sqlite3_bind_text(stmt, paramIdx, (alias as NSString).utf8String, -1, nil); paramIdx += 1
            sqlite3_bind_text(stmt, paramIdx, (prefixPattern as NSString).utf8String, -1, nil); paramIdx += 1
        } else {
            sqlite3_bind_text(stmt, paramIdx, (cleanQuery as NSString).utf8String, -1, nil); paramIdx += 1
            sqlite3_bind_text(stmt, paramIdx, (prefixPattern as NSString).utf8String, -1, nil); paramIdx += 1
            sqlite3_bind_text(stmt, paramIdx, (containsPattern as NSString).utf8String, -1, nil); paramIdx += 1
            
            sqlite3_bind_text(stmt, paramIdx, (cleanQuery as NSString).utf8String, -1, nil); paramIdx += 1
            sqlite3_bind_text(stmt, paramIdx, (prefixPattern as NSString).utf8String, -1, nil); paramIdx += 1
        }
        
        sqlite3_bind_int(stmt, paramIdx, Int32(limit))
        
        var results: [GenomicTarget] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(stmt, 0))
            let geneStr = String(cString: sqlite3_column_text(stmt, 1))
            let seqStr = String(cString: sqlite3_column_text(stmt, 2))
            
            results.append(GenomicTarget(
                id: id,
                gene: geneStr,
                sequence: seqStr,
                species: species,
                type: type
            ))
        }
        
        return results
    }
}
