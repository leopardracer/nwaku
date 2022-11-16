# Extensions for libp2p's protobuf library implementation

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  libp2p/protobuf/minprotobuf,
  libp2p/varint
 
export
  minprotobuf,
  varint


proc write3*(proto: var ProtoBuffer, field: int, value: auto) =
  if default(type(value)) != value:
    proto.write(field, value)

proc finish3*(proto: var ProtoBuffer) =
  if proto.buffer.len > 0:
    proto.finish()
  else:
    proto.offset = 0

proc `==`*(a: zint64, b: zint64): bool =
  int64(a) == int64(b)