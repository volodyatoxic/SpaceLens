import CoreGraphics
// Печатает номер окна Space Lens (для screencapture -l).
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in l where (w[kCGWindowOwnerName as String] as? String) == "Space Lens" && (w[kCGWindowLayer as String] as? Int) == 0 {
  let b = w[kCGWindowBounds as String] as! [String: Any]
  if (b["Width"] as? Double ?? 0) > 300 && (b["Height"] as? Double ?? 0) > 300 { print(w[kCGWindowNumber as String]!); break }
}
