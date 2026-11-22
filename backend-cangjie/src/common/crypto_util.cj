package hrms_backend.common

import stdx.crypto.digest.*
import stdx.encoding.hex.*

let PASSWORD_SALT = "HRMS_CANGJIE_2026_SALT:"

public func sha256Hex(input: String): String {
    let digest = SHA256()
    digest.write(input.toArray())
    let hash = digest.finish()
    return toHexString(hash)
}

public func hashPassword(rawPassword: String): String {
    return sha256Hex(PASSWORD_SALT + rawPassword)
}

public func verifyPassword(rawPassword: String, storedHash: String): Bool {
    return hashPassword(rawPassword) == storedHash
}
