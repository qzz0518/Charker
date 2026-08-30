// The adapter follows GLTFKit2's MIT-licensed sample Draco plug-in, narrowed to
// the triangle meshes used by A2687.glb. Draco itself is linked through the
// Apache-2.0 DracoSwift XCFramework; see THIRD-PARTY-NOTICES.md.

#import "CharkerDraco.h"
#import <GLTFKit2/GLTFKit2.h>

#include "draco/compression/decode.h"

static GLTFComponentType CharkerComponentTypeForDracoType(draco::DataType type) {
    switch (type) {
        case draco::DT_INT8: return GLTFComponentTypeByte;
        case draco::DT_UINT8: return GLTFComponentTypeUnsignedByte;
        case draco::DT_INT16: return GLTFComponentTypeShort;
        case draco::DT_UINT16: return GLTFComponentTypeUnsignedShort;
        case draco::DT_UINT32: return GLTFComponentTypeUnsignedInt;
        case draco::DT_FLOAT32: return GLTFComponentTypeFloat;
        default: return GLTFComponentTypeInvalid;
    }
}

static void *CharkerCopyAttributeData(const draco::PointCloud &cloud,
                                      const draco::PointAttribute &attribute,
                                      int &byteCount) {
    const int pointCount = cloud.num_points();
    const int componentCount = attribute.num_components();
    const int componentSize = draco::DataTypeLength(attribute.data_type());
    const int elementSize = componentCount * componentSize;
    byteCount = pointCount * elementSize;

    void *bytes = malloc(byteCount);
    if (bytes == nullptr) return nullptr;

    if (attribute.is_mapping_identity()) {
        memcpy(bytes, attribute.GetAddress(draco::AttributeValueIndex(0)), byteCount);
    } else {
        for (draco::PointIndex point(0); point < pointCount; ++point) {
            attribute.GetValue(
                attribute.mapped_index(point),
                static_cast<char *>(bytes) + point.value() * elementSize
            );
        }
    }
    return bytes;
}

@interface CharkerDracoDecompressor : NSObject <GLTFDracoMeshDecompressor>
@end

@implementation CharkerDracoDecompressor

+ (GLTFPrimitive *)newPrimitiveForCompressedBufferView:(GLTFBufferView *)bufferView
                                          attributeMap:(NSDictionary<NSString *, NSNumber *> *)attributeMap {
    const char *data = static_cast<const char *>(bufferView.buffer.data.bytes) + bufferView.offset;
    draco::DecoderBuffer buffer;
    buffer.Init(data, bufferView.length);

    draco::Decoder decoder;
    auto encodedType = draco::Decoder::GetEncodedGeometryType(&buffer);
    if (!encodedType.ok() || encodedType.value() != draco::TRIANGULAR_MESH) return nil;

    auto decoded = decoder.DecodeMeshFromBuffer(&buffer);
    if (!decoded.ok()) return nil;
    std::unique_ptr<draco::Mesh> mesh = std::move(decoded).value();

    NSMutableArray<GLTFAttribute *> *attributes = [NSMutableArray array];
    for (NSString *name in attributeMap) {
        const int attributeID = attributeMap[name].intValue;
        const draco::PointAttribute *attribute = mesh->GetAttributeByUniqueId(attributeID);
        if (attribute == nullptr) return nil;

        int byteCount = 0;
        void *bytes = CharkerCopyAttributeData(*mesh, *attribute, byteCount);
        if (bytes == nullptr) return nil;

        NSData *attributeData = [NSData dataWithBytesNoCopy:bytes
                                                     length:byteCount
                                               freeWhenDone:YES];
        GLTFBuffer *attributeBuffer = [[GLTFBuffer alloc] initWithData:attributeData];
        GLTFBufferView *attributeView = [[GLTFBufferView alloc]
            initWithBuffer:attributeBuffer
                    length:byteCount
                    offset:0
                    stride:0];
        const GLTFComponentType componentType =
            CharkerComponentTypeForDracoType(attribute->data_type());
        if (componentType == GLTFComponentTypeInvalid) return nil;

        GLTFAccessor *accessor = [[GLTFAccessor alloc]
            initWithBufferView:attributeView
                         offset:0
                  componentType:componentType
                      dimension:static_cast<GLTFValueDimension>(attribute->num_components())
                          count:mesh->num_points()
                     normalized:attribute->normalized()];
        [attributes addObject:[[GLTFAttribute alloc] initWithName:name accessor:accessor]];
    }

    const size_t indexCount = mesh->num_faces() * 3;
    const size_t indexByteCount = indexCount * sizeof(uint32_t);
    uint32_t *indices = static_cast<uint32_t *>(calloc(indexCount, sizeof(uint32_t)));
    if (indices == nullptr) return nil;

    for (int faceIndex = 0; faceIndex < mesh->num_faces(); ++faceIndex) {
        const auto &face = mesh->face(draco::FaceIndex(faceIndex));
        indices[faceIndex * 3] = face[0].value();
        indices[faceIndex * 3 + 1] = face[1].value();
        indices[faceIndex * 3 + 2] = face[2].value();
    }

    NSData *indexData = [NSData dataWithBytesNoCopy:indices
                                             length:indexByteCount
                                       freeWhenDone:YES];
    GLTFBuffer *indexBuffer = [[GLTFBuffer alloc] initWithData:indexData];
    GLTFBufferView *indexView = [[GLTFBufferView alloc]
        initWithBuffer:indexBuffer
                length:indexByteCount
                offset:0
                stride:0];
    GLTFAccessor *indexAccessor = [[GLTFAccessor alloc]
        initWithBufferView:indexView
                     offset:0
              componentType:GLTFComponentTypeUnsignedInt
                  dimension:GLTFValueDimensionScalar
                      count:indexCount
                 normalized:NO];

    return [[GLTFPrimitive alloc] initWithPrimitiveType:GLTFPrimitiveTypeTriangles
                                            attributes:attributes
                                               indices:indexAccessor];
}

@end

void CharkerRegisterDracoDecompressor(void) {
    GLTFAsset.dracoDecompressorClassName = NSStringFromClass(CharkerDracoDecompressor.class);
}
