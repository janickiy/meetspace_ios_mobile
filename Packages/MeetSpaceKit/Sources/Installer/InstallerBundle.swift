import Foundation
import Security

struct InstallerBundle {
    let files: [String:Data]
    let manifest: [String:Any]
    init() throws {
        let names = ["runner.py","release.json","release.sig","trust-root.pem","docker.asc"]
        files = try Dictionary(uniqueKeysWithValues: names.map { ($0, try resource($0)) })
        manifest = try object(files["release.json"]!)
        // These anchors are tied to the reviewed Android 9681bdd bundle, not downloaded metadata.
        guard sha(files["trust-root.pem"]!) == "9f16201125cd17dc9fb90a7579e78589c76ecbfdb1ee80df3428ee34d6b90dfc",
              sha(files["runner.py"]!) == "144333d90e2dff3de2ab16d9d69a4de2a5895a925edf9d2043ce35a60139143b",
              manifest["runnerSha256"] as? String == sha(files["runner.py"]!),
              manifest["dockerKeySha256"] as? String == sha(files["docker.asc"]!),
              manifest["installerVersion"] as? String == "1.0.0", manifest["profile"] as? String == "source-v1" else { throw InstallerFailure.response }
        let pem = String(decoding: files["trust-root.pem"]!, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("---") }.joined()
        guard let spki = Data(base64Encoded: pem) else { throw InstallerFailure.response }
        // SubjectPublicKeyInfo: SEQUENCE { algorithm SEQUENCE, BIT STRING { 0, PKCS1 RSA } }.
        func tlv(_ bytes: Data, _ offset: inout Int) throws -> Data {
            guard offset + 2 <= bytes.count else { throw InstallerFailure.response }
            offset += 1; var length = Int(bytes[offset]); offset += 1
            if length & 128 != 0 {
                let count = length & 127; guard count > 0, count <= 4, offset + count <= bytes.count else { throw InstallerFailure.response }
                length = 0; for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
            }
            guard offset + length <= bytes.count else { throw InstallerFailure.response }
            defer { offset += length }; return Data(bytes[offset..<offset+length])
        }
        var offset = 0; let sequence = try tlv(spki, &offset); offset = 0
        _ = try tlv(sequence, &offset); let bits = try tlv(sequence, &offset)
        guard bits.first == 0, let key = SecKeyCreateWithData(Data(bits.dropFirst()) as CFData,
            [kSecAttrKeyType:kSecAttrKeyTypeRSA,kSecAttrKeyClass:kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, files["release.json"]! as CFData, files["release.sig"]! as CFData, nil) else { throw InstallerFailure.response }
    }
    func payload(_ action: String, _ request: [String:Any]) throws -> Data {
        guard ["plan","apply","status","cancel","resume"].contains(action) else { throw InstallerFailure.response }
        let data = try canonical(["bundle":files.mapValues { $0.base64EncodedString() },"action":action,"request":request])
        let python = "import base64,json\n_d=json.loads(base64.b64decode('\(data.base64EncodedString())'))\n_b={k:base64.b64decode(v) for k,v in _d['bundle'].items()}\n_g={'__name__':'meetspace_bootstrap','BOOTSTRAP_BUNDLE':_b}\nexec(compile(_b['runner.py'],'meetspace-signed-installer','exec'),_g)\n_g['entry'](_d['action'],_d['request'])\n"
        guard python.utf8.count <= 512 * 1024 else { throw InstallerFailure.response }; return Data(python.utf8)
    }
    func parsePlan(_ data: Data) throws -> InstallerPlan {
        let value = try object(data); var unhashed = value; unhashed.removeValue(forKey: "hash")
        guard let hash = value["hash"] as? String, hash == sha(try canonical(unhashed)),
              value["runnerSha256"] as? String == manifest["runnerSha256"] as? String,
              let optionsValue = value["options"] as? [String:Any],
              let platform = value["platform"] as? [String:Any], let architecture = platform["arch"] as? String, ["amd64","arm64"].contains(architecture),
              let version = value["releaseVersion"] as? String, let commit = value["commit"] as? String,
              commit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              let expiry = value["expiresAt"] as? Double, let docker = value["docker"] as? [String:Any], let installed = docker["installed"] as? Bool else { throw InstallerFailure.response }
        let options = try JSONDecoder().decode(InstallerOptions.self, from: canonical(optionsValue)).validated()
        var effective = manifest
        if let lock = value["sourceLock"] as? [String:Any] {
            guard value["recipeSha256"] as? String == sha(try canonical(manifest)),
                  lock["repository"] as? String == "janickiy/meet-space", lock["commit"] as? String == commit,
                  lock["version"] as? String == version, lock["sourceUrl"] as? String == "https://codeload.github.com/janickiy/meet-space/tar.gz/\(commit)",
                  let sourceHash = lock["sourceSha256"] as? String, sourceHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let hashes = lock["sourceFiles"] as? [String:String], let original = manifest["sourceFiles"] as? [String:String], Set(hashes.keys) == Set(original.keys),
                  hashes.values.allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }),
                  let channel = lock["channel"] as? String, ["default-branch","prebuilt"].contains(channel) else { throw InstallerFailure.response }
            for name in ["version","commit","builtAt","sourceUrl","sourceSha256","sourceFiles"] { effective[name] = lock[name] }
            effective["backendTag"] = channel == "prebuilt" ? (lock["ref"] ?? NSNull()) : NSNull()
            if var dockerfiles = effective["dockerfiles"] as? [String:[String:Any]] {
                for (name, var file) in dockerfiles { guard let path = file["path"] as? String, let digest = hashes[path] else { throw InstallerFailure.response }; file["sha256"] = digest; dockerfiles[name] = file }
                effective["dockerfiles"] = dockerfiles
            }
        }
        guard value["releaseSha256"] as? String == sha(try canonical(effective)), effective["commit"] as? String == commit, effective["version"] as? String == version else { throw InstallerFailure.response }
        if options.imageMode == "images" {
            let repository = manifest["prebuiltRepository"] as? String ?? "janickiy/meet-space"
            guard ["janickiy/meet-space","janickiy/meetspace_docker_built"].contains(repository),
                  let lock = value["imageLock"] as? [String:Any], lock["repository"] as? String == repository,
                  lock["commit"] as? String == commit, lock["version"] as? String == version, lock["platform"] as? String == "linux/\(architecture)",
                  lock["url"] as? String == "https://github.com/\(repository)/releases/download/\(version)/meetspace-\(version)-linux-\(architecture).tar.gz",
                  let size = lock["sizeBytes"] as? Int, (1...2*1024*1024*1024).contains(size),
                  ["sha256","indexSha256"].allSatisfy({ (lock[$0] as? String)?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else { throw InstallerFailure.response }
        } else if value["imageLock"] != nil { throw InstallerFailure.response }
        return InstallerPlan(json: data, hash: hash, commit: commit, version: version, architecture: architecture,
            resourceProfile: value["resourceProfile"] as? String ?? "standard", requiresDocker: !installed || docker["installCompose"] as? Bool == true || docker["installBuildx"] as? Bool == true,
            expiresAt: Date(timeIntervalSince1970: expiry), options: options, existingJobID: value["existingJobId"] as? String, existingPlanHash: value["existingPlanHash"] as? String)
    }
}
