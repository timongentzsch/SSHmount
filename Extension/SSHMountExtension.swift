import Foundation
import FSKit

@main
struct SSHMountExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        SSHMountFileSystem()
    }
}
