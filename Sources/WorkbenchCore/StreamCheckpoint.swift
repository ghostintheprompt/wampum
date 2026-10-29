import Foundation
public final class StreamCheckpoint:@unchecked Sendable {
    public let url:URL
    private let handle:FileHandle
    private let lock=NSLock()
    private var count=0
    private var closed=false
    public init(url:URL)throws{self.url=url;try IntegrityCheck.writeNew(Data(),to:url.path);handle=try FileHandle(forWritingTo:url)}
    @discardableResult public func append(_ text:String)throws->Int {
        lock.lock();defer{lock.unlock()}
        guard !closed else{throw WorkbenchError.invalid("Stream checkpoint is closed.")}
        let data=Data(text.utf8);try handle.write(contentsOf:data);let previous=count;count+=data.count
        if count/512 != previous/512 || previous==0 {try handle.synchronize()}
        return count
    }
    public func finish()throws{lock.lock();defer{lock.unlock()};if !closed{try handle.synchronize();try handle.close();closed=true}}
    deinit{try? handle.close()}
}
