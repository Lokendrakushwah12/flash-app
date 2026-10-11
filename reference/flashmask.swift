// Usage: swift flashmask.swift in.png mask.png
// Writes the person segmentation mask (white = person) and prints faces as "x y w h" (top-left origin, px).
import Foundation
import Vision
import CoreImage

let a = CommandLine.arguments
let img = CIImage(contentsOf: URL(fileURLWithPath: a[1]))!
let ext = img.extent
let seg = VNGeneratePersonSegmentationRequest()
seg.qualityLevel = .accurate
let face = VNDetectFaceRectanglesRequest()
try VNImageRequestHandler(ciImage: img).perform([seg, face])

for f in face.results ?? [] {
    let b = VNImageRectForNormalizedRect(f.boundingBox, Int(ext.width), Int(ext.height))
    print("face", Int(b.minX), Int(ext.height - b.maxY), Int(b.width), Int(b.height))
}
var mask = CIImage(cvPixelBuffer: seg.results!.first!.pixelBuffer)
mask = mask.transformed(by: CGAffineTransform(scaleX: ext.width / mask.extent.width, y: ext.height / mask.extent.height))
try CIContext().writePNGRepresentation(of: mask.cropped(to: ext), to: URL(fileURLWithPath: a[2]), format: .L8,
                                       colorSpace: CGColorSpaceCreateDeviceGray())
