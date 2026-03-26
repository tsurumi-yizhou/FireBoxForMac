import Foundation

@objc public protocol ChatStreamSinkProtocol {
    func onStarted(_ event: NSDictionary)
    func onDelta(_ event: NSDictionary)
    func onReasoningDelta(_ event: NSDictionary)
    func onUsage(_ event: NSDictionary)
    func onCompleted(_ event: NSDictionary)
    func onError(_ event: NSDictionary)
    func onCancelled(_ event: NSDictionary)
}

/// Unified protocol:
/// - Capability methods return envelope dictionaries: {"response": ...} or {"error": "..."}
/// - Control methods return trailing error strings for failure.
@objc public protocol ServiceProtocol {
    // MARK: Common Ping

    func ping(_ message: String, withReply reply: @escaping (String) -> Void)

    // MARK: Capability

    func listModels(withReply reply: @escaping (NSDictionary) -> Void)
    func chatCompletion(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void)
    func startChatCompletionStream(_ request: NSDictionary, sink: ChatStreamSinkProtocol, withReply reply: @escaping (Int64) -> Void)
    func cancelChatCompletion(_ requestId: Int64, withReply reply: @escaping () -> Void)
    func createEmbeddings(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void)
    func callFunction(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void)

    // MARK: Control

    func shutdown(withReply reply: @escaping (String?) -> Void)
    func getVersionCode(withReply reply: @escaping (Int32, String?) -> Void)

    func getDailyStats(year: Int32, month: Int32, day: Int32, withReply reply: @escaping (NSDictionary, String?) -> Void)
    func getMonthlyStats(year: Int32, month: Int32, withReply reply: @escaping (NSDictionary, String?) -> Void)

    func listProviders(withReply reply: @escaping ([NSDictionary], String?) -> Void)
    func addProvider(_ request: NSDictionary, withReply reply: @escaping (Int32, String?) -> Void)
    func updateProvider(_ request: NSDictionary, withReply reply: @escaping (String?) -> Void)
    func deleteProvider(providerId: Int32, withReply reply: @escaping (String?) -> Void)
    func fetchProviderModels(providerId: Int32, withReply reply: @escaping ([String], String?) -> Void)

    func listRoutes(withReply reply: @escaping ([NSDictionary], String?) -> Void)
    func addRoute(_ request: NSDictionary, withReply reply: @escaping (Int32, String?) -> Void)
    func updateRoute(_ request: NSDictionary, withReply reply: @escaping (String?) -> Void)
    func deleteRoute(id: Int32, withReply reply: @escaping (String?) -> Void)

    func listConnections(withReply reply: @escaping ([NSDictionary], String?) -> Void)
    func listClientAccess(withReply reply: @escaping ([NSDictionary], String?) -> Void)
    func updateClientAccessAllowed(accessId: Int32, isAllowed: Bool, withReply reply: @escaping (String?) -> Void)
}

public enum XPCInterfaceFactory {
    public static func makeChatStreamSinkInterface() -> NSXPCInterface {
        NSXPCInterface(with: ChatStreamSinkProtocol.self)
    }

    public static func makeServiceInterface() -> NSXPCInterface {
        let serviceInterface = NSXPCInterface(with: ServiceProtocol.self)
        serviceInterface.setInterface(
            makeChatStreamSinkInterface(),
            for: #selector(ServiceProtocol.startChatCompletionStream(_:sink:withReply:)),
            argumentIndex: 1,
            ofReply: false
        )
        return serviceInterface
    }
}

public final class XPCConnectionHelper {
    public static let shared = XPCConnectionHelper()
    public static let machServiceName = "com.firebox.service"

    private init() {}

    public func createConnection() -> NSXPCConnection? {
        let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: [])
        connection.remoteObjectInterface = XPCInterfaceFactory.makeServiceInterface()
        connection.resume()
        return connection
    }

    public func getRemoteObject(from connection: NSXPCConnection) -> ServiceProtocol? {
        connection.remoteObjectProxyWithErrorHandler { _ in } as? ServiceProtocol
    }
}
