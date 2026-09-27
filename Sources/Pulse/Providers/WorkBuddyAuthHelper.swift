import Foundation

/// WorkBuddy 本地桌面客户端凭据解析与解密助手。
///
/// 当 WorkBuddy 桌面端版本升级后，`workbuddy-desktop.info` 中的 `accessToken` 可能会存储为
/// 基于 AES-256-GCM 加密的安全信封对象（形如 `{"$wbEncrypted": 1, "envelope": "..."}`）。
/// 本助手能自动探测本地 WorkBuddy 客户端运行时，并通过安全的单次隔离子进程解密出原生 JWT 凭据。
enum WorkBuddyAuthHelper {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedDecryptedToken: (envelopeHash: Int, token: String, expiresAt: Date)?

    /// 查找本机的 WorkBuddy 运行时可执行文件路径（Electron）。
    static func findWorkBuddyRuntime() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["WORKBUDDY_EXE"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let home = NSHomeDirectory()
        let appDirs = [
            "/Applications/WorkBuddy.app",
            "\(home)/Applications/WorkBuddy.app"
        ]

        for appDir in appDirs {
            let appURL = URL(fileURLWithPath: appDir)
            let plistURL = appURL.appending(path: "Contents/Info.plist")
            guard FileManager.default.fileExists(atPath: plistURL.path),
                  let plistData = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                  let exeName = plist["CFBundleExecutable"] as? String, !exeName.isEmpty else {
                continue
            }

            let exeURL = appURL.appending(path: "Contents/MacOS").appending(path: exeName)
            if FileManager.default.isExecutableFile(atPath: exeURL.path) {
                return exeURL
            }
        }

        return nil
    }

    /// 解密可能处于加密状态的 accessToken。
    /// - 若 accessToken 已经是明文字符串，直接返回；
    /// - 若 accessToken 为字典（包含 `$wbEncrypted: 1`），则调取本地运行时安全解密。
    static func resolveToken(_ rawToken: Any) -> String? {
        if let tokenStr = rawToken as? String, !tokenStr.isEmpty {
            return tokenStr
        }

        guard let tokenDict = rawToken as? [String: Any],
              let isEncrypted = tokenDict["$wbEncrypted"] as? Int, isEncrypted == 1,
              let envelopeData = try? JSONSerialization.data(withJSONObject: tokenDict),
              let envelopeString = String(data: envelopeData, encoding: .utf8)
        else {
            return nil
        }

        // 检查内存缓存
        let hash = envelopeString.hashValue
        lock.lock()
        if let cached = cachedDecryptedToken, cached.envelopeHash == hash, cached.expiresAt > Date() {
            lock.unlock()
            return cached.token
        }
        lock.unlock()

        guard let runtime = findWorkBuddyRuntime() else {
            return nil
        }

        if let decrypted = decryptWithRuntime(envelopeDict: tokenDict, runtime: runtime) {
            lock.lock()
            // 缓存 10 分钟，减少重复调用子进程开销
            cachedDecryptedToken = (hash, decrypted, Date().addingTimeInterval(600))
            lock.unlock()
            return decrypted
        }

        return nil
    }

    private static let helperScript = #"""
'use strict';
const crypto = require('crypto');
const inputLimit = 65536;
const failure = reason => { throw {reason}; };
const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
function base64(value, length) {
  if (typeof value !== 'string' || value.length > inputLimit) failure('INVALID_FORMAT');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.toString('base64') !== value || (length !== undefined && bytes.length !== length))
    failure('INVALID_FORMAT');
  return bytes;
}
function utf8(bytes) {
  const text = bytes.toString('utf8');
  if (!Buffer.from(text, 'utf8').equals(bytes)) failure('INVALID_FORMAT');
  return text;
}
function decode(value) {
  if (!object(value) || Object.keys(value).sort().join(',') !== '$wbEncrypted,envelope' || value.$wbEncrypted !== 1)
    failure('UNSUPPORTED_ENVELOPE');
  let envelope;
  try { envelope = JSON.parse(utf8(base64(value.envelope))); }
  catch (e) { failure(e.reason || 'INVALID_FORMAT'); }
  if (!object(envelope) || !Number.isInteger(envelope.suite)) failure('INVALID_FORMAT');
  if (envelope.suite !== 1) failure('UNSUPPORTED_ENVELOPE');
  if (Object.keys(envelope).sort().join(',') !== 'authTag,ciphertext,keyId,nonce,suite' ||
      typeof envelope.keyId !== 'string' || !/^[0-9a-f]{16}$/.test(envelope.keyId)) failure('INVALID_FORMAT');
  return {keyId: envelope.keyId, nonce: base64(envelope.nonce, 12),
    tag: base64(envelope.authTag, 16), ciphertext: base64(envelope.ciphertext)};
}
function nativeStorage() {
  try {
    const storage = process._linkedBinding('electron_browser_workbuddy_storage');
    if (typeof storage.loggerGet !== 'function') failure('RUNTIME_UNAVAILABLE');
    return storage;
  } catch (_) { failure('RUNTIME_UNAVAILABLE'); }
}
function decrypt(envelope) {
  let payload;
  try { payload = JSON.parse(nativeStorage().loggerGet()); }
  catch (_) { failure('RUNTIME_UNAVAILABLE'); }
  let key;
  let plaintext;
  try {
    if (!object(payload) || payload.version !== 1) failure('RUNTIME_UNAVAILABLE');
    let secret;
    try { secret = base64(payload.atRestSecretKey, 32); }
    catch (_) { failure('RUNTIME_UNAVAILABLE'); }
    const empty = secret.every(b => b === 0);
    secret.fill(0);
    if (empty) failure('RUNTIME_UNAVAILABLE');
    key = crypto.createHash('sha256').update(payload.atRestSecretKey, 'utf8').digest();
    payload = null;
    if (crypto.createHash('sha256').update(key).digest('hex').slice(0, 16) !== envelope.keyId)
      failure('KEY_MISMATCH');
    const lp = s => {
      const bytes = Buffer.from(s, 'utf8');
      const length = Buffer.alloc(4); length.writeUInt32BE(bytes.length);
      return Buffer.concat([length, bytes]);
    };
    const aad = Buffer.concat([Buffer.from('WB-AAD\0', 'ascii'), Buffer.from([1]),
      lp('WBEV1'), lp('sym-v1'), Buffer.from([0, 0, 0, 1]), lp(envelope.keyId), Buffer.from([2, 0, 0])]);
    try {
      const cipher = crypto.createDecipheriv('aes-256-gcm', key, envelope.nonce, {authTagLength: 16});
      cipher.setAAD(aad); cipher.setAuthTag(envelope.tag);
      plaintext = Buffer.concat([cipher.update(envelope.ciphertext), cipher.final()]);
    } catch (_) { failure('DECRYPT_FAILED'); }
    const token = utf8(plaintext);
    return token;
  } finally {
    if (key) key.fill(0);
    if (plaintext) plaintext.fill(0);
  }
}
let chunks = [], size = 0;
function reply(value) {
  process.stdout.write(JSON.stringify({version: 1, ...value}), () => process.exit(value.ok ? 0 : 1));
}
process.stdin.on('data', chunk => {
  size += chunk.length;
  if (size > 65536) reply({ok: false, reason: 'INVALID_FORMAT'});
  else chunks.push(chunk);
});
process.stdin.on('error', () => reply({ok: false, reason: 'HELPER_PROTOCOL'}));
process.stdin.on('end', () => {
  try {
    const request = JSON.parse(utf8(Buffer.concat(chunks)));
    chunks = [];
    if (!object(request) || request.version !== 1) failure('HELPER_PROTOCOL');
    if (request.operation === 'decrypt') {
      reply({ok: true, accessToken: decrypt(decode(request.value))});
    } else failure('HELPER_PROTOCOL');
  } catch (e) {
    reply({ok: false, reason: (e && e.reason) ? e.reason : 'HELPER_PROTOCOL'});
  }
});
"""#

    private static func decryptWithRuntime(envelopeDict: [String: Any], runtime: URL) -> String? {
        let reqPayload: [String: Any] = [
            "version": 1,
            "operation": "decrypt",
            "value": envelopeDict
        ]
        guard let reqData = try? JSONSerialization.data(withJSONObject: reqPayload) else {
            return nil
        }

        let process = Process()
        process.executableURL = runtime
        process.arguments = ["-e", helperScript]

        var env = ProcessInfo.processInfo.environment
        env["ELECTRON_RUN_AS_NODE"] = "1"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(reqData)
            try stdinPipe.fileHandleForWriting.close()

            // 设置超时等待
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                process.waitUntilExit()
                group.leave()
            }

            let result = group.wait(timeout: .now() + 5)
            if result == .timedOut {
                process.terminate()
                return nil
            }

            guard process.terminationStatus == 0 else { return nil }
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            guard let replyJson = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                  let ok = replyJson["ok"] as? Bool, ok,
                  let token = replyJson["accessToken"] as? String, !token.isEmpty
            else {
                return nil
            }

            return token
        } catch {
            return nil
        }
    }
}
