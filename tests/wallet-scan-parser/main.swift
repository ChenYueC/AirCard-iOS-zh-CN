import Foundation

let id = "abcdefghijklmnopqrstuvwxyza="
precondition(WalletScanParser.cardIDs(in: "Dashboard loading primary card: for \(id)") == [id])
precondition(WalletScanParser.cardIDs(in: "nfcd: passIDs[global] = ( \(id) )") == [id])
precondition(WalletScanParser.cardIDs(in: "/var/mobile/Library/Passes/Cards/\(id).pkpass/preview.png") == [id])
precondition(WalletScanParser.cardIDs(in: "Stockholm: activating payment pass ID: \(id) AID: A000000333010101") == [id])
precondition(WalletScanParser.cardIDs(in: "nfcd: {\"passId\": \"\(id)\", \"aid\": \"A0000000031010\"}") == [id])
precondition(WalletScanParser.cardIDs(in: "nfcd: {\"passId\": \"\(id)\"}") == [id])
precondition(WalletScanParser.cardIDs(in: "nfcd: {\"aid\": \"A0000000031010\"}").isEmpty)
precondition(WalletScanParser.cardIDs(in: "/OM6NYhwXMZrAw0sRUjR62wmF4ZQ=.pkpass").isEmpty)
print("Wallet scan parser checks passed")
