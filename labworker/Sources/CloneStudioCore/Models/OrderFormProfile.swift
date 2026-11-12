import Foundation

/// 商业引物与测序订购人抬头信息配置（通用开源默认占位元数据）
public struct OrderFormProfile: Codable, Equatable {
    public var customerName: String
    public var piName: String
    public var organization: String
    public var invoiceTitle: String
    public var phone: String
    public var email: String
    public var address: String
    public var paymentMethod: String
    public var defaultPurity: String
    public var defaultOD: Double
    
    public init(
        customerName: String = "科研人员",
        piName: String = "课题组负责人",
        organization: String = "生命科学研究院",
        invoiceTitle: String = "生命科学研究院",
        phone: String = "13800000000",
        email: String = "researcher@example.edu.cn",
        address: String = "生命科学园区实验楼A座",
        paymentMethod: String = "对公",
        defaultPurity: String = "PAGE",
        defaultOD: Double = 2.0
    ) {
        self.customerName = customerName
        self.piName = piName
        self.organization = organization
        self.invoiceTitle = invoiceTitle
        self.phone = phone
        self.email = email
        self.address = address
        self.paymentMethod = paymentMethod
        self.defaultPurity = defaultPurity
        self.defaultOD = defaultOD
    }
    
    // 兼容历史字段
    public var tsingkeAddress: String {
        get { address }
        set { address = newValue }
    }
    
    public var sangonAddress: String {
        get { address }
        set { address = newValue }
    }
}
