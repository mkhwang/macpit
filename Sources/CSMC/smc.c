#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct must be 80 bytes");

static io_connect_t g_conn = 0;

int smc_open(void) {
    if (g_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { g_conn = 0; return kr; }
    return 0;
}

void smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static int call(SMCParamStruct *in, SMCParamStruct *out) {
    if (!g_conn) { int r = smc_open(); if (r) return r; }
    size_t outSize = sizeof(SMCParamStruct);
    kern_return_t kr = IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(*in), out, &outSize);
    if (kr != KERN_SUCCESS) return kr;
    if (out->result != 0) return 0x1000 + out->result; // SMC 레벨 에러 (0x84 = key not found 등)
    return 0;
}

int smc_key_info(uint32_t key, smc_val_t *v) {
    SMCParamStruct in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    int r = call(&in, &out);
    if (r) return r;
    memset(v, 0, sizeof(*v));
    v->key = key;
    v->size = out.keyInfo.dataSize;
    v->type = out.keyInfo.dataType;
    v->attr = out.keyInfo.dataAttributes;
    return 0;
}

int smc_read(uint32_t key, smc_val_t *v) {
    int r = smc_key_info(key, v);
    if (r) return r;
    SMCParamStruct in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = v->size;
    in.data8 = SMC_CMD_READ_BYTES;
    r = call(&in, &out);
    if (r) return r;
    memcpy(v->bytes, out.bytes, sizeof(v->bytes));
    return 0;
}

int smc_write(uint32_t key, const uint8_t *bytes, uint32_t size) {
    smc_val_t info;
    int r = smc_key_info(key, &info);
    if (r) return r;
    if (info.size != size) return -2;
    SMCParamStruct in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    return call(&in, &out);
}

int smc_key_at_index(uint32_t index, uint32_t *key_out) {
    SMCParamStruct in = {0}, out = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    int r = call(&in, &out);
    if (r) return r;
    *key_out = out.key;
    return 0;
}
