import Foundation

enum DeveloperPassword {
    static let hint = "мкр и дом два раза"
    private static let salt: [UInt8] = [0xe4, 0x71, 0x11, 0x78, 0xba, 0x4d, 0x18, 0xae, 0xaa, 0x16, 0xe4, 0xff, 0x5c, 0xb9, 0x28, 0xb6]
    private static let digest: [UInt8] = [0x83, 0x3a, 0x9a, 0x8b, 0xcc, 0x52, 0x4c, 0xef, 0xc9, 0x37, 0x1c, 0xbf, 0x2b, 0x24, 0xc5, 0xdb, 0x10, 0x81, 0x46, 0x77, 0x6a, 0x52, 0x43, 0x1c, 0xbf, 0x86, 0xb3, 0xa7, 0x53, 0x1c, 0xcb, 0x3d]

    static func derive(_ password: String, salt: [UInt8], rounds: UInt32) -> [UInt8]? {
        var result = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                result.withUnsafeMutableBufferPointer { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count,
                                        saltBytes.baseAddress, saltBytes.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                        output.baseAddress, output.count)
                }
            }
        }
        return status == kCCSuccess ? result : nil
    }

    static func accepts(_ password: String) -> Bool {
        guard !password.isEmpty, password.utf8.count <= 256,
              let actual = derive(password, salt: salt, rounds: 210_000) else { return false }
        return zip(actual, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
