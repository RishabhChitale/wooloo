// usage: peer-gen <home> <herdr> <version> <peerID>
// Installs the real dispatcher under <home> and prints the real authorized_keys options.
import Foundation
let a = CommandLine.arguments
guard a.count == 5 else { FileHandle.standardError.write(Data("usage: peer-gen home herdr version peerID\n".utf8)); exit(2) }
do {
    try PeerPairing.installDispatcher(home: URL(fileURLWithPath: a[1]), herdr: a[2], version: a[3])
    print(try PeerPairing.authorizedKeyOptions(home: a[1], peerID: a[4]))
} catch { FileHandle.standardError.write(Data("peer-gen: \(error)\n".utf8)); exit(1) }
