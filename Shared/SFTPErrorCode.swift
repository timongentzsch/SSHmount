import Foundation

/// SSH_FX_* error codes from the SFTP protocol (draft-ietf-secsh-filexfer).
enum SFTPErrorCode: UInt, Sendable, CustomStringConvertible {
    case ok                 = 0
    case eof                = 1
    case noSuchFile         = 2
    case permissionDenied   = 3
    case failure            = 4
    case badMessage         = 5
    case noConnection       = 6
    case connectionLost     = 7
    case opUnsupported      = 8
    case invalidHandle      = 9
    case noSuchPath         = 10
    case fileAlreadyExists  = 11
    case writeProtect       = 12
    case noMedia            = 13
    case noSpaceOnFilesystem = 14
    case quotaExceeded      = 15
    case unknownPrincipal   = 16
    case lockConflict       = 17
    case dirNotEmpty        = 18
    case notADirectory      = 19
    case invalidFilename    = 20
    case linkLoop           = 21

    /// Map SFTP error code to the most appropriate POSIX error.
    /// Returns nil for non-error codes (ok, eof).
    var posixCode: POSIXErrorCode? {
        switch self {
        case .ok:                   return nil
        case .eof:                  return nil
        case .noSuchFile:           return .ENOENT
        case .permissionDenied:     return .EACCES
        case .failure:              return .EIO
        case .badMessage:           return .EINVAL
        case .noConnection:         return .ENOTCONN
        case .connectionLost:       return .ECONNRESET
        case .opUnsupported:        return .ENOTSUP
        case .invalidHandle:        return .EBADF
        case .noSuchPath:           return .ENOENT
        case .fileAlreadyExists:    return .EEXIST
        case .writeProtect:         return .EROFS
        case .noMedia:              return .ENXIO
        case .noSpaceOnFilesystem:  return .ENOSPC
        case .quotaExceeded:        return .EDQUOT
        case .unknownPrincipal:     return .EACCES
        case .lockConflict:         return .EAGAIN
        case .dirNotEmpty:          return .ENOTEMPTY
        case .notADirectory:        return .ENOTDIR
        case .invalidFilename:      return .EINVAL
        case .linkLoop:             return .ELOOP
        }
    }

    var description: String {
        switch self {
        case .ok:                   return "SSH_FX_OK"
        case .eof:                  return "SSH_FX_EOF"
        case .noSuchFile:           return "SSH_FX_NO_SUCH_FILE"
        case .permissionDenied:     return "SSH_FX_PERMISSION_DENIED"
        case .failure:              return "SSH_FX_FAILURE"
        case .badMessage:           return "SSH_FX_BAD_MESSAGE"
        case .noConnection:         return "SSH_FX_NO_CONNECTION"
        case .connectionLost:       return "SSH_FX_CONNECTION_LOST"
        case .opUnsupported:        return "SSH_FX_OP_UNSUPPORTED"
        case .invalidHandle:        return "SSH_FX_INVALID_HANDLE"
        case .noSuchPath:           return "SSH_FX_NO_SUCH_PATH"
        case .fileAlreadyExists:    return "SSH_FX_FILE_ALREADY_EXISTS"
        case .writeProtect:         return "SSH_FX_WRITE_PROTECT"
        case .noMedia:              return "SSH_FX_NO_MEDIA"
        case .noSpaceOnFilesystem:  return "SSH_FX_NO_SPACE_ON_FILESYSTEM"
        case .quotaExceeded:        return "SSH_FX_QUOTA_EXCEEDED"
        case .unknownPrincipal:     return "SSH_FX_UNKNOWN_PRINCIPAL"
        case .lockConflict:         return "SSH_FX_LOCK_CONFLICT"
        case .dirNotEmpty:          return "SSH_FX_DIR_NOT_EMPTY"
        case .notADirectory:        return "SSH_FX_NOT_A_DIRECTORY"
        case .invalidFilename:      return "SSH_FX_INVALID_FILENAME"
        case .linkLoop:             return "SSH_FX_LINK_LOOP"
        }
    }
}
