import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import WorkbenchCore

struct ImageAttachments {
    static func store(_ url:URL,directory:URL)throws -> String {
        let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard values.isRegularFile==true,(values.fileSize ?? Int.max)<=10_000_000 else{throw WorkbenchError.invalid("Choose a PNG or JPEG under 10 MB.")}
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let type=CGImageSourceGetType(source) as String?,["public.png","public.jpeg"].contains(type),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=properties[kCGImagePropertyPixelWidth] as? Int,let h=properties[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,w<=20000,h<=20000,w*h<=40_000_000 else {throw WorkbenchError.invalid("Unsupported image or image exceeds 40 megapixels.")}
        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1600,kCGImageSourceCreateThumbnailWithTransform:true]
        guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else{throw WorkbenchError.invalid("Image could not be decoded.")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=directory.appendingPathComponent(UUID().uuidString+".jpg")
        guard let destination=CGImageDestinationCreateWithURL(file as CFURL,UTType.jpeg.identifier as CFString,1,nil) else{throw WorkbenchError.invalid("Cannot prepare local image copy.")}
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else{throw WorkbenchError.invalid("Image conversion failed.")}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);return file.path
    }
    static func data(_ path:String,directory:URL)throws -> Data {
        let url=URL(fileURLWithPath:path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(directory.resolvingSymlinksInPath().path+"/") else{throw WorkbenchError.invalid("Attachment is outside Wampum's image store.")}
        let data=try Data(contentsOf:url);guard data.count<=4_000_000,CGImageSourceCreateWithData(data as CFData,nil) != nil else{throw WorkbenchError.invalid("Saved attachment is invalid or too large.")};return data
    }
    static func extractText(_ data:Data)throws -> String {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=false
        try VNImageRequestHandler(data:data,options:[:]).perform([request])
        return (request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n")
    }
}
