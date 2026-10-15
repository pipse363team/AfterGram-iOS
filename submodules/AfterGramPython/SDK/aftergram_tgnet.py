from aftergram_android import ConnectionsManager
from aftergram_tl import TLRPC

class SerializedData:
    def __init__(self, data=None): self.data = bytearray(data or b'');self.offset = 0
    def readInt32(self, exception=True):
        import struct
        if self.offset + 4 > len(self.data):
            if exception: raise ValueError('SerializedData is truncated')
            return 0
        value = struct.unpack_from('<i', self.data, self.offset)[0];self.offset += 4;return value
    def readInt64(self, exception=True):
        import struct
        if self.offset + 8 > len(self.data):
            if exception: raise ValueError('SerializedData is truncated')
            return 0
        value = struct.unpack_from('<q', self.data, self.offset)[0];self.offset += 8;return value
    def writeInt32(self, value):
        import struct
        self.data.extend(struct.pack('<i', int(value)))
    def writeInt64(self, value):
        import struct
        self.data.extend(struct.pack('<q', int(value)))
    def toByteArray(self): return bytes(self.data)
