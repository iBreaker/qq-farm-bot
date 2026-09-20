export {};

/**
 * protobufjs 8.4+ follows proto3's default-value elision more strictly. A few
 * QQ Farm requests are capture-verified to require an explicitly encoded zero,
 * so keep that wire-level detail local instead of pinning a vulnerable runtime.
 */
function encodeUseRequest(payload: any, requestType: any, targetType: any): Buffer {
    const target = payload?.target;
    const needsExplicitZero = target
        && Object.prototype.hasOwnProperty.call(target, 'use_config_id')
        && Number(target.use_config_id) === 0;

    if (!needsExplicitZero) {
        return Buffer.from(requestType.encode(requestType.create(payload)).finish());
    }

    const request = requestType.create(payload);
    const writer = requestType.encode(requestType.create({ item: request.item }));
    const targetWriter = targetType.encode(targetType.create(request.target));
    targetWriter.uint32(24).int64(0);
    writer.uint32(18).bytes(targetWriter.finish());
    return Buffer.from(writer.finish());
}

module.exports = { encodeUseRequest };
