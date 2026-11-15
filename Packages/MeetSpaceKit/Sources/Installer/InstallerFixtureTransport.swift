#if DEBUG
import Foundation

/// Only constructed by explicit UI-test launches. Never selected by normal Debug/Release app use.
public actor InstallerFixtureTransport: InstallerTransport {
    private var job: String?
    private var plan: [String:Any] = [:]
    public init() {}
    public func inspect(_ endpoint: InstallerEndpoint) async throws -> InstallerHostKey {
        try InstallerHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILPNQ7HnSGlQJ4uTYrYbvyr5w0zOvE6rFNQXUuI8IJZx")
    }
    public func execute(_ endpoint: InstallerEndpoint, credentials: InstallerCredentials, key: InstallerHostKey, input: Data) async throws -> Data {
        try Task.checkCancellation()
        let text = String(decoding: input, as: UTF8.self)
        if text.contains("MSPF1") || text.contains("subprocess.run") {
            let fields = ["protocol":"1","complete":"1","kernel":"Linux","distro":"ubuntu","distro_version":"24.04","arch":"x86_64","cpu":"4","ram_kib":"8388608","disk_kib":"52428800","sudo":"root","docker":"missing","docker_access":"unknown","compose":"missing","existing_paths":"no","ports_known":"yes","udp_relay_busy":"0","dns_domain":"203.0.113.10","firewall":"unknown"]
            var result = fields.map { "MSPF1\t\($0.key)\t\($0.value)" }
            result += [80,443,3478,5349,50010].map { "MSPF1\ttcp_\($0)\tfree" }
            result += [3478,50010].map { "MSPF1\tudp_\($0)\tfree" }
            return Data((result.joined(separator: "\n") + "\n").utf8)
        }
        guard let range = text.range(of: "_d=json.loads(base64.b64decode('"),
              let end = text[range.upperBound...].firstIndex(of: "'"), let data = Data(base64Encoded: String(text[range.upperBound..<end])) else { throw InstallerFailure.response }
        guard data.count <= 512 * 1024, let payload = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw InstallerFailure.response }
        guard let action = payload["action"] as? String, let request = payload["request"] as? [String:Any] else { throw InstallerFailure.response }
        let result: [String:Any]
        if action == "plan" {
            let manifest = try InstallerBundle().manifest
            plan = ["hash":"", "options":request["options"]!,"runnerSha256":manifest["runnerSha256"]!,"releaseSha256":try sha(canonical(manifest)),"commit":manifest["commit"]!,"releaseVersion":manifest["version"]!,"platform":["arch":"amd64"],"docker":["installed":false],"expiresAt":Int(Date().addingTimeInterval(900).timeIntervalSince1970),"resourceProfile":"standard"]
            plan.removeValue(forKey: "hash"); plan["hash"] = try sha(canonical(plan)); result = plan
        } else {
            if action == "apply" { job = request["jobId"] as? String; plan = request["plan"] as? [String:Any] ?? [:] }
            guard let job else { return try canonical(["protocol":"MSI1","ok":false,"errorCode":"STATE_UNAVAILABLE"]) }
            let state = action == "cancel" ? "cancelled" : action == "status" ? "completed" : "running"
            result = ["jobId":job,"planHash":plan["hash"]!,"commit":plan["commit"]!,"domain":(plan["options"] as! [String:Any])["domain"]!,"state":state,"phase":state == "completed" ? "readiness" : "docker","completedPhases":state == "completed" ? installerPhases : [],"events":[]]
        }
        return try canonical(["protocol":"MSI1","ok":true,"result":result])
    }
}
#endif
